-- Tempo real no painel: o navegador recebe um sinal quando um posto envia preços
-- ou quando um envio é aprovado ou recusado.
-- O Realtime respeita o RLS de precos (só authenticated lê), então quem não está
-- logado, como o link dos postos, não recebe nenhum evento.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'precos'
  ) then
    alter publication supabase_realtime add table public.precos;
  end if;
end $$;
