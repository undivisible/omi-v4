import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import HomePage from "../src/pages/Home";
import ArchitecturePage from "../src/pages/Architecture";
import ApiDocsPage from "../src/pages/ApiDocs";
import { buildHead } from "../src/head";

const home = renderToStaticMarkup(createElement(HomePage));
const architecture = renderToStaticMarkup(createElement(ArchitecturePage));
const apiDocs = renderToStaticMarkup(createElement(ApiDocsPage));

describe("page components", () => {
  test("home page has content", () => {
    expect(home.length).toBeGreaterThan(1000);
    expect(home).toContain("Be here. Omi keeps the thread.");
  });

  test("architecture page has content", () => {
    expect(architecture.length).toBeGreaterThan(1000);
    expect(architecture).toContain("Few moving parts, on purpose.");
  });

  test("api docs page has content", () => {
    expect(apiDocs.length).toBeGreaterThan(1000);
    expect(apiDocs).toContain("The public API");
  });

  test("home page contains capabilities text", () => {
    expect(home).toContain("Cited memory");
    expect(home).toContain("Live meetings");
    expect(home).toContain("The pendant");
    expect(home).toContain("API &amp; MCP");
    expect(home).toContain("Approve-once actions");
  });

  test("home page contains specs", () => {
    expect(home).toContain("2.5cm · 1.5cm deep");
    expect(home).toContain("150 mAh · 10–14h");
    expect(home).toContain("AES-256-GCM");
  });

  test("home page contains hardware capabilities", () => {
    expect(home).toContain("Capture");
    expect(home).toContain("Recall");
    expect(home).toContain("Automate");
    expect(home).toContain("Two and a half centimetres of listening.");
  });

  test("home page contains reach channels", () => {
    expect(home).toContain("Telegram");
    expect(home).toContain("iMessage");
    expect(home).toContain("Same brain, other inboxes.");
  });

  test("home page contains pricing and negotiate copy", () => {
    expect(home).toContain("More than 60% off");
    expect(home).toContain("Haggle with Omi. It is not a metaphor.");
    expect(home).toContain("https://omi.me/download");
  });

  test("home page contains CTA links", () => {
    expect(home).toContain("https://api.omi.tsc.hk/portal");
    expect(home).toContain("Open Omi");
    expect(home).toContain("Documentation");
  });

  test("home page ends with hub demo and stage markers", () => {
    expect(home).not.toContain("keep scrolling to access a demo of the omi desktop app");
    expect(home).not.toContain('id="get-started"');
    expect(home).toContain('id="hub-frame"');
    expect(home).toContain("data-float-replies");
    expect(home).toContain("ed-cold-mark");
    expect(home).toContain("ed-room");
    expect(home).toContain('data-computer-stage');
    expect(home).toContain('id="omi-unifies"');
    expect(home).toContain("data-dissolve-canvas");
    expect(home).toContain("data-dissolve-them");
    expect(home).toContain("data-dissolve-us");
    expect(home).toContain("The usual assistants");
    expect(home).toContain("Answers without sources");
    expect(home).toContain('data-hero');
    expect(home).toContain("ed-hardware");
    expect(home).toContain("omi-mark--on-dark");
    expect(home).toContain("foot-stage");
  });

  test("home page includes living shell chrome", () => {
    expect(home).toContain('class="field"');
    expect(home).toContain("data-omi-mark");
    expect(home).toContain("omi-mark");
    expect(home).toContain('class="rail"');
    expect(home).toContain("btn-solid");
    expect(home).toContain("reveal");
  });

  test("home page contains images", () => {
    expect(home).toContain("/omi-pendant-1200.webp");
    expect(home).toContain("/omi-worn-1200.webp");
  });

  test("architecture page contains model tiers", () => {
    expect(architecture).toContain("inception/mercury-2");
    expect(architecture).toContain("xiaomi/mimo-v2.5");
    expect(architecture).toContain("google/gemini-3.6-flash");
    expect(architecture).toContain("perplexity/sonar");
  });

  test("architecture page contains section headings", () => {
    expect(architecture).toContain("The request path");
    expect(architecture).toContain("Model tiers");
    expect(architecture).toContain("Data plane");
    expect(architecture).toContain("Memory");
    expect(architecture).toContain("Channels");
    expect(architecture).toContain("The approval gate");
    expect(architecture).toContain("FaceTime");
    expect(architecture).toContain("The pendant path");
  });

  test("architecture page contains data plane detail", () => {
    expect(architecture).toContain("omi-memory-claims");
    expect(architecture).toContain("memory_log");
    expect(architecture).toContain("POST /v1/memory/zkr-sync");
    expect(architecture).toContain("facetime_unavailable");
  });

  test("api docs page contains section headings", () => {
    expect(apiDocs).toContain("1. Authentication");
    expect(apiDocs).toContain("5. MCP server");
    expect(apiDocs).toContain("7. How the rest of it works");
    expect(apiDocs).toContain("Contents");
  });

  test("api docs page contains REST endpoints", () => {
    expect(apiDocs).toContain("/api/v1/me");
    expect(apiDocs).toContain("/api/v1/memory/search");
    expect(apiDocs).toContain("/api/v1/currents");
    expect(apiDocs).toContain("/api/v1/facetime/calls");
  });

  test("api docs page links its contents anchors", () => {
    expect(apiDocs).toContain('href="#1-authentication"');
    expect(apiDocs).toContain('href="#6-data-lifetime-and-deletion"');
  });
});

describe("head metadata", () => {
  test("buildHead produces title and meta", () => {
    const head = buildHead("Test Title", "Test Description", "/test");
    expect(head).toContain("<title>Test Title</title>");
    expect(head).toContain('content="Test Description"');
    expect(head).toContain('href="https://omi.tsc.hk/test"');
  });

  test("buildHead includes stylesheet and fonts", () => {
    const head = buildHead("Title", "Desc", "/");
    expect(head).toContain('/styles.css');
    expect(head).toContain('/scroll-stage.css');
    expect(head).toContain('/computer-stage.css');
    expect(head).toContain('/inter-latin-variable.woff2');
    expect(head).toContain('/geist-pixel-square.woff2');
  });

  test("buildHead includes enhancement scripts", () => {
    const head = buildHead("Title", "Desc", "/");
    expect(head).toContain('/main.js');
    expect(head).toContain('/mark.js');
    expect(head).toContain('/scroll-stage.js');
    expect(head).toContain('/computer-stage.js');
  });

  test("buildHead includes favicon data URI", () => {
    const head = buildHead("Title", "Desc", "/");
    expect(head).toContain('data:image/svg+xml,');
  });

  test("buildHead includes OpenGraph tags", () => {
    const head = buildHead("OG Title", "OG Desc", "/og");
    expect(head).toContain('property="og:title"');
    expect(head).toContain('content="OG Title"');
    expect(head).toContain('property="og:url"');
    expect(head).toContain('https://omi.tsc.hk/og');
  });
});

describe("server routes", () => {
  const port = 3971;
  let started = false;

  async function start(): Promise<void> {
    if (started) return;
    process.env.PORT = String(port);
    await import("../src/server");
    started = true;
  }

  test("home route serves html", async () => {
    await start();
    const res = await fetch(`http://localhost:${port}/`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("<title>Omi — private memory</title>");
    expect(html).toContain("Be here. Omi keeps the thread.");
    expect(html).toContain("Two and a half centimetres of listening.");
    expect(html).toContain("data-dissolve-canvas");
    expect(html).toContain("data-float-replies");
    expect(html).toContain("ed-cold-mark");
    expect(html).toContain('id="hub-frame"');
    expect(html).not.toContain("keep scrolling to access a demo of the omi desktop app");
  });

  test("architecture route serves html", async () => {
    await start();
    const res = await fetch(`http://localhost:${port}/architecture`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("<title>Omi — architecture</title>");
    expect(html).toContain("Few moving parts, on purpose.");
    expect(html).toContain("One table, three implementations.");
  });

  test("api docs route serves html", async () => {
    await start();
    const res = await fetch(`http://localhost:${port}/docs/api`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("<title>Omi — API reference</title>");
    expect(html).toContain("The public API");
    expect(html).toContain("4. REST endpoints");
  });

  test("unknown route is 404", async () => {
    await start();
    const res = await fetch(`http://localhost:${port}/nope`);
    expect(res.status).toBe(404);
  });
});
