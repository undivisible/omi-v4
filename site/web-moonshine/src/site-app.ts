import { join } from "node:path";
import { reactRenderer } from "@tschk/moonshine-react";
import type { Renderer, RenderContext, RouteArtifact } from "@tschk/moonshine-framework";
import { buildHead } from "./head";

export type PageEntry = {
  file: string;
  title: string;
  description: string;
  path: string;
  outFile: string;
};

export const pages: Record<string, PageEntry> = {
  "/": {
    file: join(import.meta.dir, "pages", "Home.tsx"),
    title: "Omi — private memory",
    description:
      "A private memory for the things that matter while you are busy living them.",
    path: "/",
    outFile: "index.html",
  },
  "/architecture": {
    file: join(import.meta.dir, "pages", "Architecture.tsx"),
    title: "Omi — architecture",
    description:
      "How Omi is built: one Flutter app, an embedded Rust hub with zkr memory, a Cloudflare Worker, Telegram and Sendblue channels, FaceTime via Sendblue, model tiers, D1 memory authority, and the BLE pendant path.",
    path: "/architecture",
    outFile: "architecture/index.html",
  },
  "/docs/api": {
    file: join(import.meta.dir, "pages", "ApiDocs.tsx"),
    title: "Omi — API reference",
    description:
      "The Omi public API and MCP server: authentication, scopes, rate limits, REST endpoints and MCP tools. The written contract, rendered.",
    path: "/docs/api",
    outFile: "docs/api/index.html",
  },
};

function stripExtraDoctype(html: string): string {
  return html.replace(/<!DOCTYPE html>/gi, "").replace(/^/, "<!DOCTYPE html>");
}

export const omiRenderer: Renderer = {
  name: "omi-react",
  async render(context: RenderContext): Promise<Response> {
    const response = await reactRenderer.render(context);
    const html = await response.text();
    const headInject = (context.data as { headInject?: string }).headInject ?? "";
    const modified = stripExtraDoctype(html).replace("</head>", headInject + "</head>");
    return new Response(modified, {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
  async prerender(context: RenderContext): Promise<string> {
    const html = await reactRenderer.prerender(context);
    const headInject = (context.data as { headInject?: string }).headInject ?? "";
    return stripExtraDoctype(html).replace("</head>", headInject + "</head>");
  },
};

export async function renderPageHtml(pathname: string): Promise<string | null> {
  const page = pages[pathname];
  if (!page) return null;

  const routeArtifact: RouteArtifact = {
    id: pathname,
    path: pathname,
    file: page.file,
    mode: "ssr",
    runtime: "bun",
    decision: "ssr",
    clientEntries: [],
  };

  const context: RenderContext = {
    request: new Request(`https://omi.tsc.hk${pathname === "/" ? "/" : pathname}`),
    route: routeArtifact,
    params: {},
    data: {
      headInject: buildHead(page.title, page.description, page.path),
    },
    signal: AbortSignal.timeout(30_000),
  };

  return omiRenderer.prerender(context);
}

export async function handlePageRequest(request: Request): Promise<Response> {
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
    file: page.file,
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
      headInject: buildHead(page.title, page.description, page.path),
    },
    signal: request.signal,
  };

  return omiRenderer.render(context);
}
