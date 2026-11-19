-- Recusar um preço libera o posto na hora para enviar o valor corrigido.
-- Recusar um posto: libera esse posto. "Recusar todos" de um responsável:
-- libera todos os postos recusados dele. Aprovar não muda nada aqui.
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

  -- recusado: libera o posto para enviar de novo
  if not p_aprovar then
    update public.postos set liberado_manual = true
    where ativo and id in (select pr.posto_id from public.precos pr where pr.envio_id = p_envio_id);
  end if;

  return v_n;
end;
$function$;

create or replace function public.decidir_envios(p_envio_ids uuid[], p_aprovar boolean, p_motivo text default null)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_n integer;
begin
  if coalesce(public.meu_perfil(), '') <> 'gerente' then
    raise exception 'Somente o gerente pode aprovar ou recusar preços';
  end if;

  if p_envio_ids is null or cardinality(p_envio_ids) = 0 then
    raise exception 'Nenhum envio informado';
  end if;

  update public.precos
  set status = case when p_aprovar then 'aprovado' else 'recusado' end,
      decidido_por = auth.uid(),
      decidido_em = now(),
      motivo_recusa = case when p_aprovar then null else nullif(trim(p_motivo), '') end
  where envio_id = any(p_envio_ids) and status = 'aguardando';
  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception 'Envios não encontrados ou já decididos';
  end if;

  -- recusados: libera os postos para enviarem de novo
  if not p_aprovar then
    update public.postos set liberado_manual = true
    where ativo and id in (select pr.posto_id from public.precos pr
                           where pr.envio_id = any(p_envio_ids) and pr.status = 'recusado');
  end if;

  return v_n;
end;
$function$;

revoke all on function public.decidir_envio(uuid, boolean, text) from public, anon;
grant execute on function public.decidir_envio(uuid, boolean, text) to authenticated;
revoke all on function public.decidir_envios(uuid[], boolean, text) from public, anon;
grant execute on function public.decidir_envios(uuid[], boolean, text) to authenticated;
