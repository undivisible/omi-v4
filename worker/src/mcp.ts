import { Hono } from "hono";
import { requireApiAccess } from "./api-keys";
import {
  askOmiOperation,
  createCurrentOperation,
  listConversationOperation,
  listCurrentsOperation,
  listMemoriesOperation,
  listNotesOperation,
  searchMemoryOperation,
  startFaceTimeOperation,
  type OperationResult,
} from "./public-api";
import type { ApiKeyScope, AppEnv, Bindings } from "./types";

// A direct implementation of the MCP streamable-HTTP transport: JSON-RPC 2.0
// over a single POST endpoint. The server is stateless — no session ids, no
// server-initiated stream — so every request carries its own credential and
// the whole protocol fits in one file rather than a dependency.
const mcp = new Hono<AppEnv>();

export const protocolVersion = "2025-06-18";
export const serverInfo = { name: "omi", version: "1.0.0" };
const maximumBodyBytes = 256 * 1024;
// A JSON-RPC batch is dispatched one message at a time and each message can
// cost a rate-limiter round-trip, so the batch itself is capped rather than
// left to the body size alone.
const maximumBatchMessages = 64;

// `content-length` is absent on a chunked request, so it can never be the only
// size guard: the body is read through a reader that stops at the limit, and a
// missing or unparsable header simply means "unknown" rather than zero.
const boundedPayload = async (
  request: Request,
  limit: number,
): Promise<{ payload: unknown } | { error: "too_large" | "invalid" }> => {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit)
    return { error: "too_large" };
  if (!request.body) return { error: "invalid" };
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        return { error: "too_large" };
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return { payload: JSON.parse(new TextDecoder().decode(bytes)) as unknown };
  } catch {
    return { error: "invalid" };
  } finally {
    reader.releaseLock();
  }
};

type JsonRpcId = string | number | null;

type ToolDefinition = {
  name: string;
  title: string;
  description: string;
  scope: ApiKeyScope;
  inputSchema: Record<string, unknown>;
  run: (
    env: Bindings,
    uid: string,
    input: Record<string, unknown>,
  ) => Promise<OperationResult>;
};

const object = (
  properties: Record<string, unknown>,
  required: string[] = [],
) => ({
  type: "object",
  properties,
  ...(required.length === 0 ? {} : { required }),
  additionalProperties: false,
});

const integer = (description: string, minimum: number, maximum: number) => ({
  type: "integer",
  description,
  minimum,
  maximum,
});

export const tools: ToolDefinition[] = [
  {
    name: "search_memory",
    title: "Search Omi memory",
    description:
      "Search the user's Omi memory for claims relevant to a query. Every " +
      "returned item cites the evidence it came from. Use mode 'keyword' " +
      "(default, exact term match, BM25-ranked) or 'semantic' (embedding " +
      "similarity, better for paraphrases).",
    scope: "memory:read",
    inputSchema: object(
      {
        query: {
          type: "string",
          description: "Natural-language or keyword query.",
          minLength: 1,
          maxLength: 500,
        },
        limit: integer("Maximum number of results. Defaults to 12.", 1, 50),
        mode: {
          type: "string",
          enum: ["keyword", "semantic"],
          description: "Retrieval strategy. Defaults to 'keyword'.",
        },
      },
      ["query"],
    ),
    run: (env, uid, input) => searchMemoryOperation(env, uid, input),
  },
  {
    name: "list_memories",
    title: "List Omi profile memories",
    description:
      "List the user's active profile memories (stable traits and current " +
      "context) newest first, each with its supporting evidence. Use this " +
      "for an overview; use search_memory to answer a specific question.",
    scope: "memory:read",
    inputSchema: object({
      limit: integer("Maximum number of memories. Defaults to 100.", 1, 100),
    }),
    run: (env, uid, input) => listMemoriesOperation(env, uid, input),
  },
  {
    name: "list_currents",
    title: "List Currents",
    description:
      "List the user's open Currents — proposed next actions derived from " +
      "their memory — ranked by confidence. Only surfaced and accepted " +
      "Currents are returned; dismissed, expired and snoozed ones are not.",
    scope: "currents:read",
    inputSchema: object({}),
    run: (env, uid) => listCurrentsOperation(env, uid),
  },
  {
    name: "create_current",
    title: "Create a Current",
    description:
      "Create a new Current (a proposed next action) for the user. It is " +
      "created as a candidate and surfaces to the user at surfaceAt. Omit " +
      "evidenceId unless you hold a real Omi evidence id; when omitted the " +
      "citation is recorded from the `reason` you supply.",
    scope: "currents:write",
    inputSchema: object(
      {
        title: {
          type: "string",
          description: "Short action title shown to the user.",
          minLength: 1,
          maxLength: 120,
        },
        summary: {
          type: "string",
          description: "One or two sentences of context.",
          minLength: 1,
          maxLength: 500,
        },
        reason: {
          type: "string",
          description:
            "Why this is being proposed now. Recorded as the citation when evidenceId is omitted.",
          minLength: 1,
          maxLength: 500,
        },
        proposedNextStep: {
          type: "string",
          description: "The single smallest concrete next step to take.",
          minLength: 1,
          maxLength: 500,
        },
        confidence: {
          type: "number",
          description: "Confidence from 0 to 1. Defaults to 0.7.",
          minimum: 0,
          maximum: 1,
        },
        surfaceAt: {
          type: "integer",
          description:
            "Unix epoch milliseconds at which to surface it. Defaults to now.",
          minimum: 1,
        },
        expiresAt: {
          type: "integer",
          description:
            "Unix epoch milliseconds after which it expires. Must be greater than surfaceAt. Optional.",
          minimum: 1,
        },
        evidenceId: {
          type: "string",
          description:
            "Existing Omi evidence id to cite. Omit unless you have one.",
          maxLength: 200,
        },
      },
      ["title", "summary", "reason", "proposedNextStep"],
    ),
    run: (env, uid, input) => createCurrentOperation(env, uid, input),
  },
  {
    name: "list_meeting_notes",
    title: "List meeting and daily notes",
    description:
      "List the user's generated notes — one per local day, each citing the " +
      "conversation and meeting evidence it was written from — newest first.",
    scope: "conversations:read",
    inputSchema: object({
      limit: integer("Maximum number of notes. Defaults to 50.", 1, 100),
    }),
    run: (env, uid, input) => listNotesOperation(env, uid, input),
  },
  {
    name: "list_conversation_messages",
    title: "List conversation messages",
    description:
      "Read the user's assistant conversation in cursor order. Pass the " +
      "nextCursor from a previous call as `after` to page forward.",
    scope: "conversations:read",
    inputSchema: object({
      after: integer(
        "Return messages with a cursor strictly greater than this. Defaults to 0.",
        0,
        Number.MAX_SAFE_INTEGER,
      ),
      limit: integer("Maximum number of messages. Defaults to 100.", 1, 200),
    }),
    run: (env, uid, input) => listConversationOperation(env, uid, input),
  },
  {
    name: "ask_omi",
    title: "Ask Omi",
    description:
      "Ask the user's Omi assistant a question. Omi answers with the user's " +
      "synced memory and recent conversation in context, and the exchange is " +
      "recorded in their conversation history. Requires an Omi Pro account.",
    scope: "assistant:write",
    inputSchema: object(
      {
        text: {
          type: "string",
          description: "The question or instruction to send to Omi.",
          minLength: 1,
          maxLength: 20_000,
        },
      },
      ["text"],
    ),
    run: (env, uid, input) => askOmiOperation(env, uid, input),
  },
  {
    name: "start_facetime_call",
    title: "Start a FaceTime call",
    description:
      "Place a real FaceTime Audio call. This rings the given handle on the " +
      "person's actual device immediately and returns a shareable FaceTime " +
      "link that auto-admits the first person to join. Side-effectful and not " +
      "undoable — confirm the handle with the user before calling it. The " +
      "handle must be an E.164 phone number (like +15551234567) or an email " +
      "address. Note: the upstream provider currently has FaceTime calling " +
      "switched off, so this usually returns a 'not yet available' error.",
    scope: "facetime:write",
    inputSchema: object(
      {
        handle: {
          type: "string",
          description:
            "Who to call: an E.164 phone number ('+' then 7-15 digits) or an email address.",
          minLength: 3,
          maxLength: 254,
        },
        idempotencyKey: {
          type: "string",
          description:
            "Optional caller-supplied key, 8-120 characters of [A-Za-z0-9._:-], so a retry does not place a second call.",
          minLength: 8,
          maxLength: 120,
        },
      },
      ["handle"],
    ),
    run: (env, uid, input) => startFaceTimeOperation(env, uid, input),
  },
];

const toolIndex = new Map(tools.map((tool) => [tool.name, tool]));

const listedTools = tools.map((tool) => ({
  name: tool.name,
  title: tool.title,
  description: tool.description,
  inputSchema: tool.inputSchema,
}));

// JSON-RPC 2.0 error codes; -32000 is the implementation-defined range MCP
// uses for transport-level refusals such as a missing scope.
const parseError = -32700;
const invalidRequest = -32600;
const methodNotFound = -32601;
const invalidParams = -32602;
const serverError = -32000;

const result = (id: JsonRpcId, value: unknown) => ({
  jsonrpc: "2.0",
  id,
  result: value,
});

const failure = (id: JsonRpcId, code: number, message: string) => ({
  jsonrpc: "2.0",
  id,
  error: { code, message },
});

const toolResult = (outcome: OperationResult) => ({
  content: [{ type: "text", text: JSON.stringify(outcome.body) }],
  structuredContent: outcome.body,
  isError: outcome.status >= 400,
});

export const dispatch = async (
  env: Bindings,
  uid: string,
  scopes: ApiKeyScope[] | null,
  message: Record<string, unknown>,
): Promise<Record<string, unknown> | null> => {
  if (message.jsonrpc !== "2.0" || typeof message.method !== "string")
    return failure(null, invalidRequest, "Invalid JSON-RPC request");
  const id =
    typeof message.id === "string" || typeof message.id === "number"
      ? message.id
      : null;
  // A notification carries no id and expects no reply.
  const notification = message.id === undefined;
  const method = message.method;
  if (notification)
    return method.startsWith("notifications/")
      ? null
      : failure(null, invalidRequest, "Notification method not supported");
  switch (method) {
    case "initialize":
      return result(id, {
        protocolVersion,
        capabilities: { tools: { listChanged: false } },
        serverInfo,
        instructions:
          "Omi is the user's personal memory and assistant. Search or list " +
          "their memory before answering questions about them, read their " +
          "Currents for what they intend to do next, and use ask_omi when a " +
          "synthesised answer is wanted rather than raw records.",
      });
    case "ping":
      return result(id, {});
    case "tools/list":
      return result(id, { tools: listedTools });
    case "tools/call": {
      const params =
        message.params !== null &&
        typeof message.params === "object" &&
        !Array.isArray(message.params)
          ? (message.params as Record<string, unknown>)
          : null;
      const name = params?.name;
      if (typeof name !== "string")
        return failure(id, invalidParams, "Missing tool name");
      const tool = toolIndex.get(name);
      if (!tool) return failure(id, invalidParams, `Unknown tool: ${name}`);
      const args =
        params?.arguments === undefined
          ? {}
          : params.arguments !== null &&
              typeof params.arguments === "object" &&
              !Array.isArray(params.arguments)
            ? (params.arguments as Record<string, unknown>)
            : null;
      if (args === null)
        return failure(id, invalidParams, "Tool arguments must be an object");
      if (scopes !== null && !scopes.includes(tool.scope))
        return failure(
          id,
          serverError,
          `API key is missing the ${tool.scope} scope`,
        );
      try {
        return result(id, toolResult(await tool.run(env, uid, args)));
      } catch {
        return failure(id, serverError, "Tool execution failed");
      }
    }
    default:
      return failure(id, methodNotFound, `Unknown method: ${method}`);
  }
};

mcp.use("*", requireApiAccess);

mcp.post("/", async (context) => {
  const read = await boundedPayload(context.req.raw, maximumBodyBytes);
  if ("error" in read)
    return read.error === "too_large"
      ? context.json(failure(null, invalidRequest, "Request too large"), 413)
      : context.json(failure(null, parseError, "Invalid JSON"), 400);
  const payload = read.payload;
  const uid = context.get("auth").uid;
  const key = context.get("apiKey");
  const scopes = key ? key.scopes : null;
  const messages = Array.isArray(payload) ? payload : [payload];
  if (messages.length > maximumBatchMessages)
    return context.json(
      failure(
        null,
        invalidRequest,
        `Batch too large: at most ${maximumBatchMessages} messages`,
      ),
      413,
    );
  if (
    messages.length === 0 ||
    messages.some(
      (message) =>
        message === null ||
        typeof message !== "object" ||
        Array.isArray(message),
    )
  )
    return context.json(failure(null, invalidRequest, "Invalid JSON-RPC"), 400);
  const responses: Record<string, unknown>[] = [];
  for (const message of messages) {
    const response = await dispatch(
      context.env,
      uid,
      scopes,
      message as Record<string, unknown>,
    );
    if (response) responses.push(response);
  }
  // Notifications only: the transport requires 202 with an empty body.
  if (responses.length === 0) return context.body(null, 202);
  return context.json(Array.isArray(payload) ? responses : responses[0], 200, {
    "mcp-protocol-version": protocolVersion,
  });
});

// This server never initiates messages and holds no session, so the optional
// SSE stream and session-termination verbs are declined rather than faked.
mcp.get("/", (context) =>
  context.json(failure(null, methodNotFound, "SSE stream not supported"), 405),
);
mcp.delete("/", (context) =>
  context.json(failure(null, methodNotFound, "Sessions not supported"), 405),
);

export default mcp;
