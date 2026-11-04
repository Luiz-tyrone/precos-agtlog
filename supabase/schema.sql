-- =====================================================================
-- AGT-LOG · Controle de Preços — estrutura do banco (schema public)
-- Projeto Supabase: wuzmcqvlcqisvhwapjgu
-- Fotografia tirada em 2026-11-04, direto do banco em produção.
--
-- Arquivo de REFERÊNCIA: mostra como o banco está hoje.
-- Não rode este arquivo no banco. Mudanças novas entram como migrações
-- em supabase/migrations/ (veja supabase/LEIA-ME.md).
-- Os comentários e linhas em branco das funções foram compactados;
-- a lógica é a mesma do banco.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------------------

create table public.responsaveis (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  telefone   text,
  token      text not null unique
             default replace(((gen_random_uuid())::text || (gen_random_uuid())::text), '-', ''),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

create table public.postos (
  id              uuid primary key default gen_random_uuid(),
  responsavel_id  uuid not null references public.responsaveis(id),
  nome            text not null,
  cidade          text,
  uf              text,
  cnpj            text,
  cod_sistema     text,
  lancado         boolean not null default false,
  prazo           text,
  produtos        text[] not null default '{s10,s500,arla}'::text[],
  config_tela     jsonb not null default '{}'::jsonb,
  observacao      text,
  ativo           boolean not null default true,
  criado_em       timestamptz not null default now(),
  liberado_manual boolean not null default false,
  codigo_cfa      text
);
create index postos_responsavel_id_idx on public.postos (responsavel_id);
create index postos_uf_idx on public.postos (uf);

create table public.precos (
  id            bigint generated always as identity primary key,
  posto_id      uuid not null references public.postos(id),
  produto       text not null check (produto = any (array['s10','s500','arla'])),
  valor         numeric not null check (valor >= 1 and valor <= 20),
  campos_extras jsonb not null default '{}'::jsonb,
  origem        text not null default 'posto',
  enviado_em    timestamptz not null default now()
);
create index precos_posto_id_produto_enviado_em_idx
  on public.precos (posto_id, produto, enviado_em desc);

create table public.avisos_precos (
  id              bigint generated always as identity primary key,
  posto_id        uuid not null references public.postos(id) on delete cascade,
  produto         text not null,
  ciclo_inicio    timestamptz not null,
  preco_anterior  numeric not null,
  preco_atual     numeric not null,
  diferenca       numeric not null,
  percentual      numeric,
  preco_id        bigint references public.precos(id) on delete set null,
  visualizado     boolean not null default false,
  visualizado_em  timestamptz,
  ativo           boolean not null default true,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);

create table public.cfa_exportacoes (
  id                   bigint generated always as identity primary key,
  data_inicio          date not null,
  data_fim             date not null,
  nome_arquivo         text not null,
  quantidade_registros integer not null default 0,
  gerado_por           uuid,
  criado_em            timestamptz not null default now(),
  conteudo_txt         text
);

create table public.cfa_exportacao_itens (
  id                 bigint generated always as identity primary key,
  exportacao_id      bigint not null references public.cfa_exportacoes(id) on delete cascade,
  preco_id           bigint unique references public.precos(id) on delete set null,
  criado_em          timestamptz not null default now(),
  codigo_posto_cfa   text,
  codigo_produto_cfa integer,
  valor              numeric
);

create table public.usuarios_permissoes (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  perfil     text not null check (perfil = any (array['admin','logistica'])),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- RLS (segurança por linha) e políticas
-- ---------------------------------------------------------------------
-- RLS LIGADO:    responsaveis, postos, precos
-- RLS DESLIGADO: avisos_precos, cfa_exportacoes, cfa_exportacao_itens,
--                usuarios_permissoes   (<- ver alerta em LEIA-ME.md)

alter table public.responsaveis enable row level security;
alter table public.postos       enable row level security;
alter table public.precos       enable row level security;

create policy "equipe acessa tudo" on public.responsaveis
  as permissive for all to authenticated using (true) with check (true);
create policy "equipe acessa tudo" on public.postos
  as permissive for all to authenticated using (true) with check (true);
create policy "equipe acessa tudo" on public.precos
  as permissive for all to authenticated using (true) with check (true);

-- ---------------------------------------------------------------------
-- VIEWS
-- ---------------------------------------------------------------------

create or replace view public.ultimo_preco with (security_invoker = true) as
select distinct on (posto_id, produto)
  posto_id, produto, valor, campos_extras, enviado_em
from public.precos
order by posto_id, produto, enviado_em desc;

create or replace view public.avisos_precos_painel with (security_invoker = true) as
select ap.id, ap.posto_id, p.nome as posto, p.cidade, p.uf, ap.produto,
  case ap.produto
    when 's10'  then 'Diesel S-10'
    when 's500' then 'Diesel S-500'
    when 'arla' then 'ARLA'
    else ap.produto
  end as produto_nome,
  ap.preco_anterior, ap.preco_atual, ap.diferenca, ap.percentual,
  ap.visualizado, ap.visualizado_em, ap.preco_id, ap.ciclo_inicio,
  ap.criado_em, ap.atualizado_em
from public.avisos_precos ap
join public.postos p on p.id = ap.posto_id
where ap.ativo = true;

-- Obs.: esta view NÃO tem security_invoker (roda com permissão do dono).
create or replace view public.cfa_precos_pendentes as
with ultimo_preco_semana as (
  select distinct on (pr.posto_id, pr.produto)
    pr.id as preco_id, pr.posto_id, pr.produto, pr.valor, pr.enviado_em
  from public.precos pr
  where pr.produto = any (array['s10','s500','arla'])
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

-- ---------------------------------------------------------------------
-- FUNÇÕES
-- ---------------------------------------------------------------------

-- Início do ciclo semanal: segunda-feira 08:00 (horário de Brasília).
create or replace function public.inicio_ciclo_precos(p_agora timestamptz default now())
returns timestamptz language sql stable set search_path to 'public' as $function$
  with horario as (
    select p_agora at time zone 'America/Sao_Paulo' as agora_local
  ),
  calculo as (
    select agora_local,
      date_trunc('day', agora_local)
        - ((extract(isodow from agora_local)::integer - 1) * interval '1 day')
        + interval '8 hours' as segunda_8
    from horario
  )
  select (case when agora_local >= segunda_8 then segunda_8
               else segunda_8 - interval '7 days' end) at time zone 'America/Sao_Paulo'
  from calculo;
$function$;

-- Tela do posto (posto.html): carrega os postos de um link (token).
create or replace function public.carregar_tela(p_token text)
returns jsonb language sql security definer set search_path to 'public' as $function$
  select jsonb_build_object(
    'responsavel', r.nome,
    'agora_servidor', now(),
    -- mantidos só por compatibilidade com o posto.html; não controlam mais a edição
    'inicio_ciclo', public.inicio_ciclo_precos(),
    'proxima_liberacao', null,
    'postos', coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id,
        'nome', p.nome,
        'cidade', p.cidade,
        'uf', p.uf,
        'produtos', p.produtos,
        'config', p.config_tela,
        'ultimos', coalesce((select jsonb_object_agg(u.produto, u.valor)
                             from public.ultimo_preco u where u.posto_id = p.id), '{}'::jsonb),
        'ultima_atualizacao', info.ultima_atualizacao,
        'proxima_atualizacao', null,
        'liberado_manual', coalesce(p.liberado_manual, false),
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
  where r.token = p_token and r.ativo
  group by r.id;
$function$;

-- Tela do posto (posto.html): grava os preços enviados.
create or replace function public.enviar_precos(p_token text, p_itens jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_resp uuid;
  v_item jsonb;
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

    -- se já existe preço, só altera com liberação da AGT
    if v_ultimo is not null and v_liberado = false then
      raise exception 'Alteração de preço bloqueada. Em caso de aumento ou redução nos preços dos combustíveis, solicite a liberação para atualização junto à AGT-LOG.';
    end if;
  end loop;

  -- grava os preços
  for v_item in select * from jsonb_array_elements(p_itens) loop
    insert into public.precos (posto_id, produto, valor, campos_extras)
    values ((v_item ->> 'posto_id')::uuid,
            v_item ->> 'produto',
            (v_item ->> 'valor')::numeric,
            coalesce(v_item -> 'extras', '{}'::jsonb));
    v_n := v_n + 1;
  end loop;

  -- após o envio, bloqueia novamente
  update public.postos set liberado_manual = false
  where id in (select distinct (x.item ->> 'posto_id')::uuid from jsonb_array_elements(p_itens) as x(item));

  return v_n;
end;
$function$;

-- Painel: libera um posto para alterar preço.
create or replace function public.liberar_edicao_preco(p_posto_id uuid)
returns boolean language plpgsql security definer set search_path to 'public' as $function$
begin
  update public.postos set liberado_manual = true where id = p_posto_id and ativo = true;
  if not found then
    raise exception 'Posto não encontrado';
  end if;
  return true;
end;
$function$;

-- Painel: libera todos os postos de um responsável.
create or replace function public.liberar_edicao_responsavel(p_responsavel_id uuid)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_quantidade integer;
begin
  update public.postos set liberado_manual = true
  where responsavel_id = p_responsavel_id and ativo = true;
  get diagnostics v_quantidade = row_count;
  return v_quantidade;
end;
$function$;

-- Painel: marca um aviso de aumento como visto.
create or replace function public.marcar_aviso_visualizado(p_aviso_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  update public.avisos_precos
  set visualizado = true, visualizado_em = now(), atualizado_em = now()
  where id = p_aviso_id and ativo = true;
end;
$function$;

-- Painel: marca todos os avisos como vistos.
create or replace function public.marcar_todos_avisos_visualizados()
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_quantidade integer;
begin
  update public.avisos_precos
  set visualizado = true, visualizado_em = now(), atualizado_em = now()
  where ativo = true and visualizado = false;
  get diagnostics v_quantidade = row_count;
  return v_quantidade;
end;
$function$;

-- Painel: perfil do usuário logado ('admin' ou 'logistica').
create or replace function public.meu_perfil()
returns text language sql security definer set search_path to 'public' as $function$
  select perfil from public.usuarios_permissoes
  where user_id = auth.uid() and ativo = true
  limit 1;
$function$;

-- Painel: gera o TXT de exportação para o CFA com os preços pendentes da semana.
create or replace function public.gerar_exportacao_cfa(p_data_inicio date, p_data_fim date, p_postos uuid[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_exportacao_id bigint;
  v_nome_arquivo text;
  v_conteudo text;
  v_itens jsonb;
  v_quantidade integer;
begin
  if p_data_inicio is null or p_data_fim is null then
    raise exception 'Informe a data inicial e a data final';
  end if;
  if p_data_fim < p_data_inicio then
    raise exception 'A data final não pode ser menor que a data inicial';
  end if;

  -- fotografia dos registros pendentes (todos, ou só os postos informados)
  select jsonb_agg(jsonb_build_object(
           'preco_id', preco_id, 'posto_id', posto_id, 'codigo_cfa', codigo_cfa,
           'codigo_produto_cfa', codigo_produto_cfa, 'valor', valor)
         order by posto, codigo_produto_cfa)
    into v_itens
  from public.cfa_precos_pendentes
  where p_postos is null or posto_id = any(p_postos);

  if v_itens is null or jsonb_array_length(v_itens) = 0 then
    raise exception 'Não existem preços pendentes para exportação';
  end if;

  v_quantidade := jsonb_array_length(v_itens);

  v_nome_arquivo := 'CFA_PRECOS_' || to_char(p_data_inicio, 'DD-MM-YYYY')
    || '_A_' || to_char(p_data_fim, 'DD-MM-YYYY')
    || '_' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24MISS') || '.txt';

  v_conteudo := 'CODIGO_POSTO;DATA_INICIO;DATA_FIM;CODIGO_PRODUTO;VALOR' || E'\n' ||
    (select string_agg(format('%s;%s;%s;%s;%s',
              item->>'codigo_cfa',
              to_char(p_data_inicio, 'DD/MM/YYYY'),
              to_char(p_data_fim, 'DD/MM/YYYY'),
              item->>'codigo_produto_cfa',
              replace(to_char((item->>'valor')::numeric, 'FM999999990.00'), '.', ',')),
            E'\n')
     from jsonb_array_elements(v_itens) as item);

  insert into public.cfa_exportacoes
    (data_inicio, data_fim, nome_arquivo, quantidade_registros, gerado_por, conteudo_txt)
  values (p_data_inicio, p_data_fim, v_nome_arquivo, v_quantidade, auth.uid(), v_conteudo)
  returning id into v_exportacao_id;

  -- marca exatamente quais preços entraram nesse TXT
  insert into public.cfa_exportacao_itens
    (exportacao_id, preco_id, codigo_posto_cfa, codigo_produto_cfa, valor)
  select v_exportacao_id, (item->>'preco_id')::bigint, item->>'codigo_cfa',
         (item->>'codigo_produto_cfa')::integer, (item->>'valor')::numeric
  from jsonb_array_elements(v_itens) as item;

  return jsonb_build_object(
    'exportacao_id', v_exportacao_id,
    'nome_arquivo', v_nome_arquivo,
    'quantidade_registros', v_quantidade,
    'conteudo_txt', v_conteudo);
end;
$function$;

-- Gatilho: cria um aviso quando um posto envia preço maior que o anterior.
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

  -- preço imediatamente anterior do mesmo posto e produto
  select pr.valor into v_preco_anterior
  from public.precos pr
  where pr.posto_id = new.posto_id
    and pr.produto = new.produto
    and pr.id <> new.id
    and (pr.enviado_em < new.enviado_em
         or (pr.enviado_em = new.enviado_em and pr.id < new.id))
  order by pr.enviado_em desc, pr.id desc
  limit 1;

  if v_preco_anterior is null then
    return new;  -- primeiro preço: sem base de comparação
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

-- ---------------------------------------------------------------------
-- GATILHOS
-- ---------------------------------------------------------------------

create trigger trg_processar_aviso_aumento_preco
  after insert on public.precos
  for each row execute function public.processar_aviso_aumento_preco();
