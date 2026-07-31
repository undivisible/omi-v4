import { join } from "node:path";
import { createBunServer } from "@tschk/moonshine-deploy-bun";
import { crepusRenderer } from "@tschk/crepus-moonshine";
import type { Renderer, RenderContext, RouteArtifact } from "@tschk/moonshine-framework";
import type { CrepusIr } from "@tschk/crepus-moonshine";
import { homeIr, architectureIr, apiDocsIr } from "./ir";
import { buildHead } from "./head";

type PageEntry = {
  ir: CrepusIr;
  title: string;
  description: string;
  path: string;
};

const pages: Record<string, PageEntry> = {
  "/": {
    ir: homeIr,
    title: "Omi — guided hub",
    description: "A live, guided Omi hub running on disclosed sample data.",
    path: "/",
  },
  "/architecture": {
    ir: architectureIr,
    title: "Omi — architecture",
    description:
      "How Omi is built: one Flutter app, an embedded Rust hub with zkr memory, a Cloudflare Worker, Telegram and Sendblue channels, FaceTime via Sendblue, model tiers, D1 memory authority, and the BLE pendant path.",
    path: "/architecture",
  },
  "/docs/api": {
    ir: apiDocsIr,
    title: "Omi — API reference",
    description:
      "The Omi public API and MCP server: authentication, scopes, rate limits, REST endpoints and MCP tools. The written contract, rendered.",
    path: "/docs/api",
  },
};

function stripExtraDoctype(html: string): string {
  return html.replace(/<!DOCTYPE html>/gi, "").replace(/^/, "<!DOCTYPE html>");
}

const omiRenderer: Renderer = {
  name: "omi-crepus",
  async render(context: RenderContext): Promise<Response> {
    const response = await crepusRenderer.render(context);
    const html = await response.text();
    const headInject = (context.data as { headInject?: string }).headInject ?? "";
    const modified = stripExtraDoctype(html).replace("</head>", headInject + "</head>");
    return new Response(modified, {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
  async prerender(context: RenderContext): Promise<string> {
    const html = await crepusRenderer.prerender(context);
    const headInject = (context.data as { headInject?: string }).headInject ?? "";
    return stripExtraDoctype(html).replace("</head>", headInject + "</head>");
  },
};

async function fetch(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const pathname = url.pathname.replace(/\/+$/, "") || "/";

  const page = pages[pathname];
  if (!page) {
    return new Response("Not Found", {
      status: 404,
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  }

  const routeArtifact: RouteArtifact = {
    id: pathname,
    path: pathname,
    file: "",
    mode: "ssr",
    runtime: "bun",
    decision: "ssr",
    clientEntries: [],
  };

  const context: RenderContext = {
    request,
    route: routeArtifact,
    params: {},
    data: {
      root: page.ir.root,
      version: page.ir.version,
      headInject: buildHead(page.title, page.description, page.path),
    },
    signal: request.signal,
  };

  return omiRenderer.render(context);
}

const root = import.meta.dir;
const publicDir = join(root, "..", "public");

const server = createBunServer({
  fetch,
  port: Number(process.env.PORT) || 3000,
  staticDir: publicDir,
});

console.log(`omi moonshine → ${server.url.origin}`);
