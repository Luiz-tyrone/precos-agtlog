# AGT-LOG · Controle de preços de combustível

Memória do projeto para as próximas sessões. Atualizado em 18/11/2026.

## Como falar com o usuário
- Sempre em **português do Brasil**, simples e direto. O usuário não é programador.
  - Explique termos técnicos com exemplo do próprio sistema.
  - Use tabelas curtas para resumir.
- Antes de apagar dados, mostre o que vai ser apagado (posto, produto, valor, data).
- Depois de qualquer mudança no banco, confira e mostre o resultado.

## O sistema
- Site estático, sem build:
  - `index.html`: painel da equipe, com login;
  - `posto.html`: tela do responsável do posto, sem login, acessada por um link com token;
  - `config.js`: URL e chave pública do Supabase;
  - `logo.png`.
- Banco: Supabase, projeto **`wuzmcqvlcqisvhwapjgu`** (nome `precos-agtlog`, organização agt).
  - O conector do Supabase no claude.ai precisa estar ligado nessa organização. Já houve conexão em outra conta, que só mostrava o projeto `site-jave`.
- Detalhes do banco, migrações e histórico de operações: `supabase/LEIA-ME.md`. Leia antes de mexer no banco.
- Toda mudança no banco vira:
  - um arquivo em `supabase/migrations/`, com a versão que o Supabase devolver em `list_migrations`;
  - uma atualização no `supabase/schema.sql` e no `supabase/LEIA-ME.md`.
- Git:
  - trabalhar na branch `claude/supabase-integration-h4bc62`;
  - ir para a `main` por PR. O usuário pede "mande" ou "envie" quando quer que publique, o que significa PR e merge.
  - O PR #5 (tempo real e selo vermelho) entrou na `main` em 18/11.
  - Também em 18/11: filtro por estado e cidade na tela Aprovações. É só na tela, sem mudança no banco.
    - Com filtro, "Aprovar tudo" vira "Aprovar os N filtrados" e chama `decidir_envios` só com os ids visíveis.
    - Sem filtro, continua chamando `aprovar_todos_envios`.

## Perfis de usuário (tabela `usuarios_permissoes`: user_id, perfil, ativo)
| Perfil | Pode |
|---|---|
| `gerente` | Tudo, e é o **único que aprova ou recusa preços**. O banco garante isso em `decidir_envio(s)`, `aprovar_todos_envios` e no gatilho `proteger_status_preco`. |
| `admin` | Tudo, menos aprovar. Só ele vê o botão "Consultar no WhatsApp". |
| `logistica` | Só as telas Painel de preços e Avisos. |

- Liberar um usuário novo (a conta é criada pelo usuário em Supabase → Authentication → Users):
  ```sql
  insert into public.usuarios_permissoes (user_id, perfil)
  select id, 'gerente' from auth.users where email = 'x@y.com'
  on conflict (user_id) do update set perfil = excluded.perfil, ativo = true;
  ```
- Conta apagada e recriada perde o perfil, porque o perfil é apagado junto com a conta. Para trocar a senha, oriente a usar "Send password recovery".
- Para ver os usuários atuais: `auth.users` com `left join` em `usuarios_permissoes`.
- O cadastro público está desligado (`disable_signup: true`, conferido em 18/11).
- **Atenção:** fora a aprovação, as restrições de perfil existem só na tela. O RLS é "authenticated acessa tudo". Se entrarem mais usuários de Logística, vale fechar isso no banco.

## Situação dos dados
- **Operação real começou em 18/11/2026.** Os dados de teste foram apagados nesse dia: preços, aprovações, avisos e CFA.
  - Às 09:36 o usuário mandou um envio de teste do Posto Tigrão, que também foi apagado.
- Cadastros mantidos: 104 postos e 47 responsáveis.
- Cópias de limpezas anteriores no esquema `backup` (tabelas `*_20261104` e `*_20261117`). Apagar só se o usuário pedir: `drop schema backup cascade`.
- Fluxo de preço:
  1. O posto envia (`enviar_precos`) e o envio fica `aguardando`.
  2. O gerente aprova ou recusa.
  3. Só o preço `aprovado` vale para o último preço, o histórico, a exportação CFA e os avisos de aumento.
  - Depois do primeiro envio, o posto só envia de novo se for liberado (`liberado_manual`).

## Painel em tempo real (desde 18/11)
- O Realtime do Supabase está ligado na tabela `precos` (migração `20261118122229_realtime_precos`).
- O painel escuta INSERT e UPDATE, espera 2 segundos, recarrega com `atualizarSistema()` e mostra o aviso "Novo envio de preços".
- Para conferir se um painel aberto está conectado:
  `select count(*) from realtime.subscription where entity = 'public.precos'::regclass`.
- Ainda **não foi confirmado com o servidor real**. Pergunte ao usuário se o teste funcionou.

## Limitações do ambiente de nuvem do Claude
- WebSocket não passa pelo proxy, então não dá para testar o Realtime de verdade daqui.
- Testes de tela: Playwright com o Supabase simulado. Intercepte `**/supabase-js@*/**` e sirva um `window.supabase` falso com `auth`, `rpc`, `from` (Proxy encadeável), `channel` e `realtime.setAuth`. Sirva o repositório por um servidor http local.
- O conector do Supabase não apaga Edge Functions. O formulário de segredos (`create_edge_function_secret`) estava desligado em 18/11.

## Pendências
- **Assistente de IA (texto e voz): PAUSADO.** Situação e próximos passos no topo de `docs/plano-assistente-ia.md`.
  - A função `assistente-teste` está publicada, mas sem segredos responde 401 para tudo.
- Recomendado ao usuário: ligar "Leaked password protection" em Supabase → Authentication.
- Avisos de segurança que já existiam:
  - a view `cfa_precos_pendentes` é SECURITY DEFINER;
  - as RPCs SECURITY DEFINER podem ser chamadas por `authenticated`.
