-- Aprovação de preços pelo gerente.
-- Todo preço enviado pelo posto entra como 'aguardando'. Só o perfil
-- 'gerente' aprova ou recusa. Só preço aprovado vale: último preço,
-- exportação CFA e aviso de aumento.

-- 1. Perfil novo: gerente --------------------------------------------
alter table public.usuarios_permissoes drop constraint usuarios_permissoes_perfil_check;
alter table public.usuarios_permissoes add constraint usuarios_permissoes_perfil_check
  check (perfil = any (array['admin','logistica','gerente']));

-- 2. Situação de cada preço -------------------------------------------
-- aguardando: enviado pelo posto, esperando o gerente
-- aprovado / recusado: decisão do gerente
-- substituido: posto enviou de novo (após liberação) antes da decisão
alter table public.precos
  add column status text not null default 'aguardando'
    check (status = any (array['aguardando','aprovado','recusado','substituido'])),
  add column envio_id uuid,
  add column decidido_por uuid references auth.users(id) on delete set null,
  add column decidido_em timestamptz,
  add column motivo_recusa text;

-- preços enviados antes desta regra já valiam: ficam aprovados
update public.precos set status = 'aprovado';

create index precos_envio_id_idx on public.precos (envio_id);
create index precos_aguardando_idx on public.precos (posto_id) where status = 'aguardando';

-- 3. Trava: ninguém além do gerente muda preço já enviado ---------------
create or replace function public.proteger_status_preco()
returns trigger language plpgsql set search_path to 'public' as $function$
declare
  v_gerente boolean := coalesce(public.meu_perfil(), '') = 'gerente';
begin
  if v_gerente then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'aguardando' then
      raise exception 'Somente o gerente aprova preços';
    end if;
    return new;
  end if;

  -- única mudança permitida fora do gerente: o próprio envio do posto
  -- marca o envio anterior, ainda não decidido, como substituído
  if old.status = 'aguardando' and new.status = 'substituido'
     and new.valor = old.valor and new.produto = old.produto and new.posto_id = old.posto_id then
    return new;
  end if;

  raise exception 'Somente o gerente aprova ou recusa preços';
end;
$function$;

create trigger trg_proteger_status_preco
  before insert or update on public.precos
  for each row execute function public.proteger_status_preco();

-- 4. Só preço aprovado vale ---------------------------------------------
create or replace view public.ultimo_preco with (security_invoker = true) as
select distinct on (posto_id, produto)
  posto_id, produto, valor, campos_extras, enviado_em
from public.precos
where status = 'aprovado'
order by posto_id, produto, enviado_em desc, id desc;

create or replace view public.cfa_precos_pendentes as
with ultimo_preco_semana as (
  select distinct on (pr.posto_id, pr.produto)
    pr.id as preco_id, pr.posto_id, pr.produto, pr.valor, pr.enviado_em
  from public.precos pr
  where pr.produto = any (array['s10','s500','arla'])
    and pr.status = 'aprovado'
    and pr.enviado_em >= public.inicio_ciclo_precos()
  order by pr.posto_id, pr.produto, pr.enviado_em desc, pr.id desc
)
select ups.preco_id, ups.posto_id, p.codigo_cfa, p.nome as posto, p.cidade, p.uf,
  ups.produto,
  case ups.produto when 's10' then 2 when 's500' then 3 when 'arla' then 4 end as codigo_produto_cfa,
  ups.valor, ups.enviado_em
from ultimo_preco_semana ups
join public.postos p on p.id = ups.posto_id
left join public.cfa_exportacao_itens cei on cei.preco_id = ups.preco_id
where p.ativo = true
  and p.codigo_cfa is not null
  and trim(both from p.codigo_cfa) <> ''
  and cei.preco_id is null;

-- 5. Aviso de aumento: gerado na aprovação, comparando com o último aprovado
create or replace function public.processar_aviso_aumento_preco()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  v_preco_anterior numeric;
  v_diferenca numeric;
  v_percentual numeric;
begin
  if new.produto not in ('s10', 's500', 'arla') then
    return new;
  end if;

  select pr.valor into v_preco_anterior
  from public.precos pr
  where pr.posto_id = new.posto_id
    and pr.produto = new.produto
    and pr.status = 'aprovado'
    and pr.id <> new.id
    and (pr.enviado_em < new.enviado_em
         or (pr.enviado_em = new.enviado_em and pr.id < new.id))
  order by pr.enviado_em desc, pr.id desc
  limit 1;

  if v_preco_anterior is null then
    return new;  -- primeiro preço aprovado: sem base de comparação
  end if;

  if new.valor > v_preco_anterior then
    v_diferenca := round(new.valor - v_preco_anterior, 4);
    if v_preco_anterior <> 0 then
      v_percentual := round(((new.valor - v_preco_anterior) / v_preco_anterior) * 100, 2);
    else
      v_percentual := null;
    end if;

    insert into public.avisos_precos (
      posto_id, produto, ciclo_inicio, preco_anterior, preco_atual, diferenca,
      percentual, preco_id, visualizado, visualizado_em, ativo, criado_em, atualizado_em)
    values (
      new.posto_id, new.produto, public.inicio_ciclo_precos(new.enviado_em),
      v_preco_anterior, new.valor, v_diferenca, v_percentual, new.id,
      false, null, true, now(), now());
  end if;

  return new;
end;
$function$;

drop trigger trg_processar_aviso_aumento_preco on public.precos;
create trigger trg_processar_aviso_aumento_preco
  after update of status on public.precos
  for each row
  when (new.status = 'aprovado' and old.status is distinct from 'aprovado')
  execute function public.processar_aviso_aumento_preco();

-- 6. Envio do posto: grava como 'aguardando', um envio_id por posto ----
create or replace function public.enviar_precos(p_token text, p_itens jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_resp uuid;
  v_posto uuid;
  v_liberado boolean;
  v_ultimo timestamptz;
  v_n integer := 0;
begin
  -- valida link
  select id into v_resp from public.responsaveis where token = p_token and ativo;
  if v_resp is null then
    raise exception 'Link inválido';
  end if;

  -- valida itens
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'Nenhum preço informado';
  end if;

  -- valida cada posto
  for v_posto in
    select distinct (x.item ->> 'posto_id')::uuid from jsonb_array_elements(p_itens) as x(item)
  loop
    v_liberado := false;
    v_ultimo := null;

    select coalesce(p.liberado_manual, false), max(pr.enviado_em)
      into v_liberado, v_ultimo
    from public.postos p
    left join public.precos pr on pr.posto_id = p.id
    where p.id = v_posto and p.responsavel_id = v_resp and p.ativo
    group by p.id, p.liberado_manual;

    if not found then
      raise exception 'Posto não pertence a este link';
    end if;

    -- se já existe envio, só altera com liberação da AGT
    if v_ultimo is not null and v_liberado = false then
      raise exception 'Alteração de preço bloqueada. Em caso de aumento ou redução nos preços dos combustíveis, solicite a liberação para atualização junto à AGT-LOG.';
    end if;
  end loop;

  -- envio anterior ainda não decidido deixa de valer
  update public.precos set status = 'substituido'
  where status = 'aguardando'
    and posto_id in (select distinct (x.item ->> 'posto_id')::uuid from jsonb_array_elements(p_itens) as x(item));

  -- grava os preços, aguardando aprovação do gerente
  insert into public.precos (posto_id, produto, valor, campos_extras, envio_id)
  select (x.item ->> 'posto_id')::uuid,
         x.item ->> 'produto',
         (x.item ->> 'valor')::numeric,
         coalesce(x.item -> 'extras', '{}'::jsonb),
         e.envio_id
  from jsonb_array_elements(p_itens) as x(item)
  join (
    select d.posto_id, gen_random_uuid() as envio_id
    from (select distinct (y.item ->> 'posto_id')::uuid as posto_id
          from jsonb_array_elements(p_itens) as y(item)) d
  ) e on e.posto_id = (x.item ->> 'posto_id')::uuid;
  get diagnostics v_n = row_count;

  -- após o envio, bloqueia novamente
  update public.postos set liberado_manual = false
  where id in (select distinct (x.item ->> 'posto_id')::uuid from jsonb_array_elements(p_itens) as x(item));

  return v_n;
end;
$function$;

-- 7. Tela do posto: mostra a situação do último envio --------------------
create or replace function public.carregar_tela(p_token text)
returns jsonb language sql security definer set search_path to 'public' as $function$
  select jsonb_build_object(
    'responsavel', r.nome,
    'agora_servidor', now(),
    -- mantidos só por compatibilidade com o posto.html antigo
    'inicio_ciclo', public.inicio_ciclo_precos(),
    'proxima_liberacao', null,
    'postos', coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id,
        'nome', p.nome,
        'cidade', p.cidade,
        'uf', p.uf,
        'produtos', p.produtos,
        'config', p.config_tela,
        -- últimos preços aprovados
        'ultimos', coalesce((select jsonb_object_agg(u.produto, u.valor)
                             from public.ultimo_preco u where u.posto_id = p.id), '{}'::jsonb),
        'ultima_atualizacao', info.ultima_atualizacao,
        'proxima_atualizacao', null,
        'liberado_manual', coalesce(p.liberado_manual, false),
        -- último envio do posto: aguardando, aprovado ou recusado
        'situacao', env.status,
        'situacao_enviado_em', env.enviado_em,
        'situacao_valores', env.valores,
        'motivo_recusa', env.motivo_recusa,
        -- regra de edição: liberado pela AGT, ou primeiro envio do posto
        'pode_editar', case
            when coalesce(p.liberado_manual, false) = true then true
            when info.ultima_atualizacao is null then true
            else false end,
        'segundos_restantes', 0
      ) order by p.nome), '[]'::jsonb)
  )
  from public.responsaveis r
  join public.postos p on p.responsavel_id = r.id and p.ativo
  left join lateral (
    select max(pr.enviado_em) as ultima_atualizacao
    from public.precos pr where pr.posto_id = p.id
  ) info on true
  left join lateral (
    select pr.status, max(pr.enviado_em) as enviado_em,
           jsonb_object_agg(pr.produto, pr.valor) as valores,
           max(pr.motivo_recusa) as motivo_recusa
    from public.precos pr
    where pr.posto_id = p.id and pr.status <> 'substituido'
    group by pr.envio_id, pr.status
    order by max(pr.enviado_em) desc, max(pr.id) desc
    limit 1
  ) env on true
  where r.token = p_token and r.ativo
  group by r.id;
$function$;

-- 8. Lista de envios para o painel ----------------------------------------
create or replace view public.envios_aprovacao with (security_invoker = true) as
select pr.envio_id, pr.posto_id, p.nome as posto, p.cidade, p.uf,
  rs.nome as responsavel, pr.status,
  min(pr.enviado_em) as enviado_em,
  max(pr.decidido_em) as decidido_em,
  max(pr.motivo_recusa) as motivo_recusa,
  jsonb_object_agg(pr.produto, pr.valor) as valores
from public.precos pr
join public.postos p on p.id = pr.posto_id
join public.responsaveis rs on rs.id = p.responsavel_id
where pr.envio_id is not null
group by pr.envio_id, pr.posto_id, p.nome, p.cidade, p.uf, rs.nome, pr.status;

-- 9. Decisão do gerente ----------------------------------------------------
create or replace function public.decidir_envio(p_envio_id uuid, p_aprovar boolean, p_motivo text default null)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_n integer;
begin
  if coalesce(public.meu_perfil(), '') <> 'gerente' then
    raise exception 'Somente o gerente pode aprovar ou recusar preços';
  end if;

  update public.precos
  set status = case when p_aprovar then 'aprovado' else 'recusado' end,
      decidido_por = auth.uid(),
      decidido_em = now(),
      motivo_recusa = case when p_aprovar then null else nullif(trim(p_motivo), '') end
  where envio_id = p_envio_id and status = 'aguardando';
  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception 'Envio não encontrado ou já decidido';
  end if;
  return v_n;
end;
$function$;

create or replace function public.aprovar_todos_envios()
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_n integer;
begin
  if coalesce(public.meu_perfil(), '') <> 'gerente' then
    raise exception 'Somente o gerente pode aprovar preços';
  end if;

  update public.precos
  set status = 'aprovado', decidido_por = auth.uid(), decidido_em = now(), motivo_recusa = null
  where status = 'aguardando';
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

revoke all on function public.decidir_envio(uuid, boolean, text) from public, anon;
revoke all on function public.aprovar_todos_envios() from public, anon;
grant execute on function public.decidir_envio(uuid, boolean, text) to authenticated;
grant execute on function public.aprovar_todos_envios() to authenticated;
revoke all on function public.proteger_status_preco() from public, anon, authenticated;
