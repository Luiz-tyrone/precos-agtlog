-- Aplicada em 2026-11-04 no projeto wuzmcqvlcqisvhwapjgu.
-- Liga a segurança por linha (RLS) nas 4 tabelas que estavam abertas
-- para a chave pública (anon).

alter table public.avisos_precos        enable row level security;
alter table public.cfa_exportacoes      enable row level security;
alter table public.cfa_exportacao_itens enable row level security;
alter table public.usuarios_permissoes  enable row level security;

-- Equipe logada (painel) continua com acesso total, como antes.
create policy "equipe acessa tudo" on public.avisos_precos
  as permissive for all to authenticated using (true) with check (true);
create policy "equipe acessa tudo" on public.cfa_exportacoes
  as permissive for all to authenticated using (true) with check (true);
create policy "equipe acessa tudo" on public.cfa_exportacao_itens
  as permissive for all to authenticated using (true) with check (true);

-- Perfis de acesso: cada usuário logado só lê o próprio registro.
-- Ninguém altera pela API; a função meu_perfil() continua funcionando.
create policy "usuario le o proprio perfil" on public.usuarios_permissoes
  as permissive for select to authenticated using (user_id = (select auth.uid()));
