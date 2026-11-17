# Plano: Assistente de IA (texto e voz) no painel

> **Situação em 17/11/2026 (para retomar numa sessão nova):**
> - Plano aprovado. Modelo do teste: **Claude Haiku 5.5**.
> - ✅ Código da função de teste pronto: `supabase/functions/assistente-teste/index.ts`. Ainda **não publicado**.
> - ❌ A publicação travou porque o conector do Supabase não tinha permissão para Edge Functions.
>   - O usuário escolheu a **opção (a)**: reconectar o Supabase no claude.ai com a permissão de Edge Functions.
> - Próximos passos:
>   1. Publicar `assistente-teste` com `verify_jwt=false`, porque a função tem autenticação própria pelo cabeçalho `x-teste`.
>   2. Pedir os segredos `ANTHROPIC_API_KEY` e `IA_TESTE_SENHA` pelo formulário do Supabase (`create_edge_function_secret`).
>   3. Rodar de 10 a 15 perguntas reais e montar o relatório: resposta, valor certo, acerto e custo.
> - Pendência do usuário: criar a conta em console.anthropic.com, colocar crédito e gerar a API key. A chave nunca vai no chat.

## Contexto
O diretor e a equipe querem perguntar coisas do banco em linguagem natural, por texto ou voz. Exemplos:
- "qual o preço do posto X?"
- "quando o posto Y atualizou pela última vez?"
- "qual o diesel mais barato em Goiânia?"

Hoje isso exige abrir o painel e filtrar na mão. A proposta é um chat dentro do `index.html`.

Decisões já tomadas:
- Só **admin** e **gerente** usam o chat.
- Voz nos dois sentidos: o usuário fala a pergunta e ouve a resposta.
- A IA vê os preços **aprovados** e também as **pendências** de aprovação.
- O modelo ainda está **em aberto**. A tabela abaixo é para a escolha.

## Comparação de preços das IAs
Os valores são em US$ por 1 milhão de tokens (entrada / saída), pesquisados em novembro de 2026.
- Claude: tabela oficial da Anthropic.
- Outras empresas: sites agregadores, porque a página oficial não apareceu na busca. Confirme na página oficial antes de decidir.

A estimativa de custo por pergunta supõe ~6 mil tokens de entrada e ~400 de saída. Isso cobre instruções, ferramentas e dados do banco. O dólar foi convertido a ~R$ 5,50. O custo mensal supõe 50 perguntas por dia.

| Empresa | Modelo | Entrada / saída | ~Custo por pergunta | ~Custo por mês |
|---|---|---|---|---|
| Anthropic | Claude Haiku 5.5 | $0,10 / $0,50 | R$ 0,005 | R$ 7 |
| Anthropic | Claude Sonnet 5.5 | $2 / $10 | R$ 0,09 | R$ 130 |
| Anthropic | Claude Opus 5.5 | $4 / $20 | R$ 0,18 | R$ 265 |
| OpenAI | GPT-6 Luna | $0,10 / $0,50 | R$ 0,005 | R$ 7 |
| OpenAI | GPT-6.1 Terra | $1 / $5 | R$ 0,04 | R$ 65 |
| OpenAI | GPT-6.1 Sol | $2 / $10 | R$ 0,09 | R$ 130 |
| Google | Gemini 3.1 Flash-Lite | $0,25 / $1,50 | R$ 0,01 | R$ 17 |
| Google | Gemini 3 Flash | $0,50 / $3 | R$ 0,02 | R$ 35 |
| DeepSeek | V4.1 Flash | $0,30 / $1,20 | R$ 0,013 | R$ 20 |

Observações:
- **O custo real deve ficar menor.** O cache de prompt reaproveita as instruções que se repetem em toda pergunta, e isso derruba o custo de entrada.
- **DeepSeek** processa os dados na China. Não é recomendado para dados comerciais.
- **Trocar de empresa depois exige reescrever a função.** Mudar de modelo dentro da mesma empresa é só trocar uma linha.
- **Recomendação:** começar com **Claude Haiku 5.5**. O trabalho é simples, consultar e resumir, e o custo é quase zero. Se errar muito, sobe para o Sonnet 5.5 trocando uma linha.

## Arquitetura
```
index.html (botão 💬, só admin e gerente)
   └─ sb.functions.invoke("assistente", {mensagens})  ← vai junto o token do usuário logado
Supabase Edge Function "assistente"
   ├─ confere o perfil pelo RPC meu_perfil (admin ou gerente, senão erro 403)
   ├─ chama o Claude com ferramentas de SÓ LEITURA
   ├─ executa as ferramentas com o token do usuário, então o RLS vale normalmente
   └─ devolve a resposta em texto
```
A chave da IA fica como segredo da Edge Function (`ANTHROPIC_API_KEY`). Ela nunca vai para o repositório nem para o navegador.

## Etapa 0: teste com o Haiku (antes de tudo)
Objetivo: ver se o Claude Haiku 5.5 responde bem com dados reais, sem mexer no site.

Passos:
1. Você salva a chave em Supabase → Edge Functions → Secrets com o nome `ANTHROPIC_API_KEY`.
2. Eu publico só a Edge Function `assistente-teste`, com `MODELO = "claude-haiku-5-5"`, as 5 ferramentas de leitura e a checagem de admin ou gerente.
   - Não cria tabela nova e não muda nada no `index.html`.
   - A ferramenta `mais_barato` faz a consulta direto pela view `ultimo_preco`, sem RPC nova.
3. Eu chamo a função com 10 a 15 perguntas reais, por exemplo:
   - "preço do posto X";
   - "última atualização do posto Y";
   - "S-10 mais barato em Goiânia";
   - "o que está aguardando aprovação".
4. Te entrego um relatório com:
   - cada pergunta e a resposta da IA;
   - o valor certo tirado do banco, para comparar;
   - acerto ou erro;
   - tokens e custo real de cada pergunta.
5. Você decide entre três caminhos:
   - seguir com o Haiku;
   - testar o Sonnet 5.5 com as mesmas perguntas, trocando uma linha;
   - parar.

Como funciona o acesso no teste:
- A função de teste não tem login. Ela só responde a quem enviar uma senha de teste no cabeçalho `x-teste`.
  - Essa senha é aleatória e fica guardada nos Secrets como `IA_TESTE_SENHA`.
- A função lê o banco com a chave interna do Supabase, que já vem pronta dentro das Edge Functions. Essa chave nunca sai do servidor.
  - As ferramentas da IA só fazem SELECT nas views e tabelas listadas, então ela não consegue alterar nada.
- Terminado o teste, a função `assistente-teste` é apagada.
  - A versão final usa o login do usuário e exige perfil admin ou gerente, como está descrito abaixo.

## Etapas (só depois do teste aprovado)

### 1. Banco: migração `supabase/migrations/2026111812xxxx_assistente_ia.sql`
- Tabela `ia_uso`: id, user_id, criado_em, pergunta, tokens_entrada, tokens_saida, modelo. Com RLS, só gerente e admin leem. Serve para acompanhar o custo.
- RPC `ia_mais_barato(p_cidade text, p_produto text)`: usa a view `ultimo_preco` junto com `postos` e ordena por valor. A view já filtra só preços aprovados.
- RPC `ia_historico(p_posto uuid, p_dias int)`: lê `precos` com `status='aprovado'`.
- As duas RPCs rodam com `security invoker`, revogam acesso de `anon` e liberam só `authenticated`.
- Limite diário por usuário, por exemplo 200 perguntas, conferido pela contagem em `ia_uso`. Protege o custo.

### 2. Edge Function: `supabase/functions/assistente/index.ts` (Deno + `npm:@anthropic-ai/sdk`)
- `verify_jwt` ligado. Monta o cliente Supabase com o cabeçalho `Authorization` do usuário.
- Aceita só perfil `admin` ou `gerente`, conferido pelo RPC `meu_perfil` que já existe.
- Ferramentas, todas de leitura e com `strict: true`:
  - `buscar_postos(texto?, cidade?, uf?)`: lê a tabela `postos` com responsáveis, como o painel já faz.
  - `ultimo_preco(posto_id)`: valor por produto e data da última atualização, pela view `ultimo_preco`.
  - `mais_barato(cidade, produto)`: chama o RPC `ia_mais_barato`.
  - `historico(posto_id, dias)`: chama o RPC `ia_historico`.
  - `pendentes_aprovacao()`: lê a view `envios_aprovacao` com `status=aguardando`.
- Instrução do sistema em português:
  - os produtos são `s10`, `s500` e `arla` (S-10, S-500 e Arla);
  - responder curto, em formato bom para ser lido em voz alta;
  - não inventar valores;
  - dizer a data do preço.
- O laço de ferramentas tem no máximo 6 voltas. Cache de prompt nas instruções e nas ferramentas.
- O modelo fica numa constante só, `MODELO`, para a troca ser fácil.
- Registra o uso em `ia_uso` e devolve `{resposta}`.

### 3. Tela: `index.html`
- Botão flutuante 💬, que só aparece quando `meu_perfil` (já chamado em `index.html:638`) devolve admin ou gerente.
- Painel de chat:
  - lista de mensagens, campo de texto e botões 🎤 e 🔊 (ligar e desligar a voz);
  - funciona também no celular.
- Voz de entrada: `SpeechRecognition` / `webkitSpeechRecognition` com `lang="pt-BR"`. Se o navegador não suportar, o 🎤 fica oculto.
- Voz de saída: `speechSynthesis` com uma voz pt-BR. A preferência de ligado ou desligado fica salva no `localStorage`.
- O histórico da conversa fica na memória e vai para a função a cada pergunta, limitado às últimas 10 mensagens.
- Reaproveita o cliente `sb` (`index.html:600`) e os estilos que já existem.

### 4. Documentação
- `supabase/LEIA-ME.md`: nova seção "Assistente de IA", explicando como funciona, quem usa, custo e como trocar o modelo.
- Atualizar a tabela "Como o site usa o banco" no mesmo arquivo.

### 5. O que o usuário precisa fazer
- Criar uma conta em console.anthropic.com, colocar crédito e gerar a chave.
- Salvar a chave em Supabase → Edge Functions → Secrets com o nome `ANTHROPIC_API_KEY`. Não colar no chat.
- Opcional: no console, definir um limite de gasto mensal.

## Verificação
1. Migração testada dentro de `begin … raise exception` com a role `authenticated` simulada:
   - `ia_mais_barato` só traz preços aprovados;
   - `anon` não consegue executar.
2. Publicar a função. Depois de salvar a chave:
   - fazer as 3 perguntas de exemplo com dados reais e comparar com o painel;
   - testar com um usuário de logística, que deve receber 403.
3. Playwright com Supabase simulado, no mesmo estilo do script `ui.js` da scratchpad:
   - o botão aparece para gerente e admin e não aparece para logística;
   - enviar uma pergunta mostra a resposta;
   - o 🎤 some quando o navegador não suporta;
   - nenhum erro no console.
4. Conferir que `ia_uso` registra os tokens. Rodar os avisos de segurança do Supabase (advisors).
5. Commit na branch `claude/supabase-integration-h4bc62` (recriada a partir de `origin/main`), PR e merge depois da sua aprovação.

## Fontes de preço
- Claude: tabela oficial da Anthropic, versão de 03/11/2026.
- OpenAI: benchlm.ai/openai/api-pricing e cloudzero.com/blog/openai-pricing.
- Gemini: requesty.ai/blog/gemini-api-pricing e developer.puter.com/tutorials/gemini-api-pricing.
- DeepSeek: benchlm.ai/deepseek/api-pricing.
