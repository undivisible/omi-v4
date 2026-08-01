import {
  App,
  Badge,
  Divider,
  Ln,
  PrimaryActions,
  Section,
  T,
  V,
  OmiMarkHeroSmall,
  codeStyle,
  giantStyle,
  labelStyle,
  midStyle,
  noteStyle,
} from "../App";

const apiRail: Array<[string, string]> = [
  ["top", "API"],
  ["1-authentication", "Auth"],
  ["4-rest-endpoints", "REST"],
  ["5-mcp-server", "MCP"],
];

const apiSections: Array<[string, string]> = [
  ["1-authentication", "1. Authentication"],
  ["2-rate-limits", "2. Rate limits"],
  ["3-conventions", "3. Conventions"],
  ["4-rest-endpoints", "4. REST endpoints"],
  ["5-mcp-server", "5. MCP server"],
  ["6-data-lifetime-and-deletion", "6. Data lifetime and deletion"],
  ["7-how-the-rest-of-it-works", "7. How the rest of it works"],
];

const restEndpoints: Array<[string, string]> = [
  ["GET /api/v1/me", " — account identity"],
  ["GET /api/v1/memory/search", " — search memories"],
  ["GET /api/v1/memories", " — list memories"],
  ["GET /api/v1/currents", " — list currents"],
  ["POST /api/v1/currents", " — create a current"],
  ["GET /api/v1/conversations/messages", " — list conversation messages"],
  ["GET /api/v1/notes", " — list meeting notes"],
  ["POST /api/v1/assistant/messages", " — send a message to the assistant"],
  ["POST /api/v1/facetime/calls", " — place a FaceTime call"],
  ["POST /api/v1/speech/transcriptions", " — transcribe audio"],
  ["POST /api/v1/speech/synthesis", " — synthesise speech"],
];

function ApiHero() {
  return (
    <Section>
      <div className="section-intro reveal" id="top">
        <OmiMarkHeroSmall />
        <Badge style={labelStyle}>Reference</Badge>
        <T style={giantStyle}>The public API</T>
        <V gap={16}>
          <V gap={0}>
            <T style={midStyle}>Two surfaces on one credential: a REST API under </T>
            <T style={codeStyle}>/api/v1</T>
            <T style={midStyle}> and an MCP server at </T>
            <T style={codeStyle}>/mcp</T>
            <T style={midStyle}>
              . Everything here is scoped to a single account.
            </T>
          </V>
          <PrimaryActions />
        </V>
      </div>
    </Section>
  );
}

function ApiContents() {
  return (
    <Section>
      <T style={labelStyle}>Contents</T>
      <ol>
        {apiSections.map(([anchor, label]) => (
          <li key={anchor}>
            <Ln href={`#${anchor}`}>{label}</Ln>
          </li>
        ))}
      </ol>
    </Section>
  );
}

function ApiReference() {
  return (
    <Section>
      <V gap={8}>
        <T style={{ ...midStyle, fontWeight: 700 }}>1. Authentication</T>
        <T style={noteStyle}>
          Every request to /api/v1/* and /mcp must carry a credential. Two are
          accepted: API keys (recommended for programmatic access) sent as a
          bearer token, and Firebase ID tokens. Keys are matched with
          ^omi_sk_[0-9a-f]{"{8}"}_[A-Za-z0-9_-]{"{43}"}$. Only the SHA-256 digest
          is persisted. Scopes include memory:read, currents:read,
          currents:write, conversations:read, assistant:write, facetime:write,
          and speech:write.
        </T>
      </V>
      <Divider />
      <V gap={8}>
        <T style={{ ...midStyle, fontWeight: 700 }}>2. Rate limits</T>
        <T style={noteStyle}>
          Rate limits are per-user, not per-key. Managed-AI admission gates
          concurrent model sessions by cost. The budget is shared across both
          surfaces.
        </T>
      </V>
      <Divider />
      <V gap={8}>
        <T style={{ ...midStyle, fontWeight: 700 }}>3. Conventions</T>
        <T style={noteStyle}>
          {'All responses are JSON. Timestamps are Unix milliseconds. Errors use {"error":"...","scope":"..."} for missing scopes and JSON-RPC error code -32000 on MCP.'}
        </T>
      </V>
      <Divider />
      <V gap={8}>
        <T style={{ ...midStyle, fontWeight: 700 }}>4. REST endpoints</T>
        <ul>
          {restEndpoints.map(([endpoint, note]) => (
            <li key={endpoint}>
              <T style={codeStyle}>{endpoint}</T>
              <T>{note}</T>
            </li>
          ))}
        </ul>
      </V>
      <Divider />
      <V gap={8}>
        <T style={{ ...midStyle, fontWeight: 700 }}>5. MCP server</T>
        <T style={noteStyle}>
          The MCP server at /mcp uses MCP streamable HTTP (JSON-RPC 2.0). It
          accepts the same credentials and enforces the same scopes. Supported
          methods include initialize, tools/list, and tools/call. Tools include
          search_memory, list_memories, list_currents, create_current,
          list_conversation_messages, list_meeting_notes, ask_omi,
          start_facetime_call, transcribe_audio, and speak_text.
        </T>
      </V>
      <Divider />
      <V gap={8}>
        <T style={{ ...midStyle, fontWeight: 700 }}>
          6. Data lifetime and deletion
        </T>
        <T style={noteStyle}>
          Account deletion removes all data: memories, currents, conversations,
          notes, and channel bindings. The memory log is truncated and the
          Vectorize index is purged.
        </T>
      </V>
      <Divider />
      <V gap={8}>
        <T style={{ ...midStyle, fontWeight: 700 }}>
          7. How the rest of it works
        </T>
        <T style={noteStyle}>
          The Worker verifies the credential, resolves the uid, and scopes every
          query. The hub is linked into the Flutter app. Channels share one
          ordered conversation. See /architecture for the full system design.
        </T>
      </V>
    </Section>
  );
}

export function ApiDocsPage() {
  return (
    <App rail={apiRail}>
      <ApiHero />
      <Divider />
      <ApiContents />
      <Divider />
      <ApiReference />
    </App>
  );
}

export default ApiDocsPage;
