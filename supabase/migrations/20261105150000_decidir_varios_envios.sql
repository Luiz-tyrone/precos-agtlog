-- Gerente aprova ou recusa vários envios de uma vez
-- (ex.: todos os postos de um responsável). Tudo ou nada.
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
  return v_n;
end;
$function$;

revoke all on function public.decidir_envios(uuid[], boolean, text) from public, anon;
grant execute on function public.decidir_envios(uuid[], boolean, text) to authenticated;
