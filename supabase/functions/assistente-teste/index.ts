// Assistente de IA - VERSÃO DE TESTE (etapa 0 do plano).
// Sem login: só responde a quem enviar o cabeçalho x-teste igual ao segredo IA_TESTE_SENHA.
// Lê o banco com a chave interna do Supabase, mas as ferramentas só fazem SELECT.
// Será apagada depois do teste.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MODELO = "claude-haiku-5-5";
const MAX_VOLTAS = 6;

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const ia = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

const str = (d: string) => ({ type: ["string", "null"], description: d });

const FERRAMENTAS: Anthropic.Tool[] = [
  {
    name: "buscar_postos",
    description:
      "Procura postos pelo nome, cidade e/ou UF. Devolve id, nome, cidade, uf, se está ativo, produtos que vende e o responsável. Use antes das outras ferramentas para achar o posto_id. Passe null no que não quiser filtrar.",
    input_schema: {
      type: "object",
      properties: { nome: str("parte do nome do posto"), cidade: str("cidade"), uf: str("UF com 2 letras") },
      required: ["nome", "cidade", "uf"],
      additionalProperties: false,
    },
    strict: true,
  },
  {
    name: "ultimo_preco",
    description: "Último preço APROVADO de cada produto de um posto, com a data e hora do envio.",
    input_schema: {
      type: "object",
      properties: { posto_id: { type: "string", description: "id do posto (uuid)" } },
      required: ["posto_id"],
      additionalProperties: false,
    },
    strict: true,
  },
  {
    name: "mais_barato",
    description:
      "Ranking dos postos ativos pelo último preço APROVADO de um produto, do mais barato ao mais caro, filtrando por cidade e/ou UF (null para não filtrar).",
    input_schema: {
      type: "object",
      properties: {
        produto: { type: "string", enum: ["s10", "s500", "arla"] },
        cidade: str("cidade"),
        uf: str("UF com 2 letras"),
      },
      required: ["produto", "cidade", "uf"],
      additionalProperties: false,
    },
    strict: true,
  },
  {
    name: "historico",
    description: "Preços APROVADOS de um posto nos últimos N dias, do mais recente ao mais antigo.",
    input_schema: {
      type: "object",
      properties: {
        posto_id: { type: "string", description: "id do posto (uuid)" },
        dias: { type: "integer", description: "quantos dias para trás (1 a 365)" },
      },
      required: ["posto_id", "dias"],
      additionalProperties: false,
    },
    strict: true,
  },
  {
    name: "pendentes_aprovacao",
    description: "Envios de preço que estão aguardando aprovação do gerente, com posto, cidade, responsável, data e valores.",
    input_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
    strict: true,
  },
];

// Escapa curingas do ilike
const like = (s: string) => `%${s.replace(/[%_,()]/g, " ").trim()}%`;

async function executar(nome: string, e: Record<string, unknown>): Promise<unknown> {
  switch (nome) {
    case "buscar_postos": {
      let q = db.from("postos").select("id,nome,cidade,uf,ativo,produtos,responsaveis(nome)").order("nome").limit(40);
      if (e.nome) q = q.ilike("nome", like(String(e.nome)));
      if (e.cidade) q = q.ilike("cidade", like(String(e.cidade)));
      if (e.uf) q = q.ilike("uf", String(e.uf).trim());
      const { data, error } = await q;
      if (error) throw error;
      return data;
    }
    case "ultimo_preco": {
      const { data, error } = await db.from("ultimo_preco").select("produto,valor,enviado_em").eq("posto_id", e.posto_id);
      if (error) throw error;
      return data.length ? data : "Nenhum preço aprovado para este posto.";
    }
    case "mais_barato": {
      let q = db.from("postos").select("id,nome,cidade,uf").eq("ativo", true);
      if (e.cidade) q = q.ilike("cidade", like(String(e.cidade)));
      if (e.uf) q = q.ilike("uf", String(e.uf).trim());
      const { data: postos, error } = await q;
      if (error) throw error;
      if (!postos.length) return "Nenhum posto ativo encontrado com esse filtro.";
      const { data: precos, error: e2 } = await db
        .from("ultimo_preco").select("posto_id,valor,enviado_em")
        .eq("produto", e.produto).in("posto_id", postos.map((p) => p.id));
      if (e2) throw e2;
      const porId = new Map(postos.map((p) => [p.id, p]));
      const lista = precos
        .map((p) => ({ ...porId.get(p.posto_id), valor: p.valor, enviado_em: p.enviado_em }))
        .sort((a, b) => Number(a.valor) - Number(b.valor));
      return lista.length ? lista.slice(0, 15) : "Nenhum preço aprovado desse produto nesses postos.";
    }
    case "historico": {
      const dias = Math.min(Math.max(Number(e.dias) || 30, 1), 365);
      const desde = new Date(Date.now() - dias * 864e5).toISOString();
      const { data, error } = await db
        .from("precos").select("produto,valor,enviado_em")
        .eq("posto_id", e.posto_id).eq("status", "aprovado").gte("enviado_em", desde)
        .order("enviado_em", { ascending: false }).limit(150);
      if (error) throw error;
      return data.length ? data : `Nenhum preço aprovado nos últimos ${dias} dias.`;
    }
    case "pendentes_aprovacao": {
      const { data, error } = await db
        .from("envios_aprovacao").select("posto,cidade,uf,responsavel,enviado_em,valores")
        .eq("status", "aguardando").order("enviado_em");
      if (error) throw error;
      return data.length ? data : "Nada aguardando aprovação.";
    }
  }
  throw new Error(`Ferramenta desconhecida: ${nome}`);
}

const SISTEMA = `Você é o assistente de preços de combustível da AGT Log. Responde perguntas da equipe sobre os postos parceiros e os preços que eles enviam.

Regras:
- Use sempre as ferramentas para buscar dados. Nunca invente postos, valores ou datas.
- Produtos: s10 = Diesel S-10, s500 = Diesel S-500, arla = Arla 32. "Diesel" sem especificar = S-10.
- Valores em reais por litro, com 2 casas (ex.: R$ 6,19). Sempre diga a data do preço.
- Datas no fuso de Brasília (America/Sao_Paulo), formato dd/mm/aaaa e hora quando fizer sentido.
- Se o nome do posto bater com vários, liste as opções e pergunte qual é.
- Só preços aprovados contam como preço oficial. Envios aguardando aprovação são só pendências.
- Respostas curtas e diretas, em português do Brasil, em texto corrido simples (vão ser lidas em voz alta): sem tabelas, sem markdown, sem emojis.`;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  const senha = Deno.env.get("IA_TESTE_SENHA");
  if (!senha || req.headers.get("x-teste") !== senha) return json({ erro: "não autorizado" }, 401);
  if (req.method !== "POST") return json({ erro: "use POST" }, 405);

  const { pergunta, historico = [] } = await req.json();
  if (!pergunta || typeof pergunta !== "string") return json({ erro: "falta pergunta" }, 400);

  const hoje = new Date().toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo" });
  const mensagens: Anthropic.MessageParam[] = [
    ...historico.slice(-10),
    { role: "user", content: `${pergunta}\n\n(agora: ${hoje})` },
  ];
  const uso = { entrada: 0, saida: 0, cache_leitura: 0, cache_escrita: 0 };
  const chamadas: { ferramenta: string; entrada: unknown }[] = [];

  try {
    for (let volta = 1; volta <= MAX_VOLTAS; volta++) {
      const r = await ia.messages.create({
        model: MODELO,
        max_tokens: 4000,
        system: [{ type: "text", text: SISTEMA, cache_control: { type: "ephemeral" } }],
        tools: FERRAMENTAS,
        output_config: { effort: "low" },
        messages: mensagens,
      });
      uso.entrada += r.usage.input_tokens;
      uso.saida += r.usage.output_tokens;
      uso.cache_leitura += r.usage.cache_read_input_tokens ?? 0;
      uso.cache_escrita += r.usage.cache_creation_input_tokens ?? 0;
      mensagens.push({ role: "assistant", content: r.content });

      if (r.stop_reason === "refusal") return json({ resposta: "Não consigo responder isso.", uso, chamadas, voltas: volta });
      if (r.stop_reason !== "tool_use") {
        const texto = r.content.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
        return json({ resposta: texto, uso, chamadas, voltas: volta, modelo: MODELO });
      }

      const resultados: Anthropic.ToolResultBlockParam[] = [];
      for (const b of r.content) {
        if (b.type !== "tool_use") continue;
        chamadas.push({ ferramenta: b.name, entrada: b.input });
        try {
          const saida = await executar(b.name, b.input as Record<string, unknown>);
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: JSON.stringify(saida) });
        } catch (err) {
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: String((err as Error).message ?? err), is_error: true });
        }
      }
      mensagens.push({ role: "user", content: resultados });
    }
    return json({ resposta: "Não consegui concluir a busca. Tente reformular a pergunta.", uso, chamadas, voltas: MAX_VOLTAS });
  } catch (err) {
    if (err instanceof Anthropic.APIError) return json({ erro: `IA: ${err.status} ${err.message}` }, 502);
    return json({ erro: String(err) }, 500);
  }
});
