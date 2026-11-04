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

## Histórico de operações nos dados

### 2026-11-04: limpeza dos dados fictícios (início da operação real)

Apagados todos os dados de teste:

| Tabela | Registros apagados |
|--------|-------------------|
| `precos` (28/07 a 04/11/2026) | 2.399 |
| `avisos_precos` | 1.226 |
| `cfa_exportacoes` | 5 |
| `cfa_exportacao_itens` | 101 |

Postos (104), responsáveis (47), links e usuários não foram alterados.

Cópia de segurança no esquema `backup` (não acessível pelo site nem pela chave
pública): `backup.precos_20261104`, `backup.avisos_precos_20261104`,
`backup.cfa_exportacoes_20261104`, `backup.cfa_exportacao_itens_20261104`.
Quando não forem mais necessárias: `drop schema backup cascade;`
