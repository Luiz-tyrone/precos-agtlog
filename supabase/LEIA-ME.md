# Banco de dados (Supabase)

Projeto: `wuzmcqvlcqisvhwapjgu` (organização **agt**)

## Arquivos

- `schema.sql`: cópia de referência de como o banco está hoje (tabelas, views,
  funções, gatilho e regras de acesso). Não precisa rodar no banco.
- `migrations/`: cada mudança nova no banco vira um arquivo aqui, com data no nome
  (ex.: `20261104120000_ativar_rls.sql`). O mesmo SQL é aplicado no Supabase pelo
  Claude, e o `schema.sql` é atualizado junto.

## Como o site usa o banco

| Tela | Acesso | O que usa |
|------|--------|-----------|
| `posto.html` | sem login, pelo link com token | RPCs `carregar_tela` e `enviar_precos` |
| `index.html` | com login (equipe AGT) | tabelas `postos`, `precos`, `responsaveis`, `cfa_exportacoes`; views `ultimo_preco`, `avisos_precos_painel`, `cfa_precos_pendentes`; RPCs `meu_perfil`, `liberar_edicao_*`, `marcar_*_visualizado(s)`, `gerar_exportacao_cfa` |

## Pontos de atenção (verificado em 2026-11-04)

1. ~~RLS desligado em 4 tabelas~~ **Corrigido em 2026-11-04** (migração
   `20261104172722_ativar_rls_tabelas_expostas`). Testado antes e depois: tela do
   posto, painel, avisos, exportação CFA e gatilho de aumento funcionando.
2. A view `cfa_precos_pendentes` roda com permissão do dono (sem `security_invoker`).
3. As RPCs do painel podem ser chamadas por qualquer usuário logado. Isso só é seguro
   se o cadastro público de usuários estiver desligado no Supabase
   (Authentication → Sign In / Providers → "Allow new users to sign up").
4. A proteção contra senhas vazadas está desligada (Authentication → Passwords).
