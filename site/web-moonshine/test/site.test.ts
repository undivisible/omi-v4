import { describe, expect, test } from "bun:test";
import { homeIr, architectureIr, apiDocsIr } from "../src/ir";
import { buildHead } from "../src/head";

describe("Crepus IR documents", () => {
  test("home IR has content", () => {
    expect(homeIr.root.length).toBeGreaterThan(0);
    expect(homeIr.version).toBe(1);
  });

  test("architecture IR has content", () => {
    expect(architectureIr.root.length).toBeGreaterThan(0);
    expect(architectureIr.version).toBe(1);
  });

  test("api docs IR has content", () => {
    expect(apiDocsIr.root.length).toBeGreaterThan(0);
    expect(apiDocsIr.version).toBe(1);
  });

  test("home IR contains capabilities text", () => {
    const json = JSON.stringify(homeIr);
    expect(json).toContain("Memory you can check");
    expect(json).toContain("Live meetings");
    expect(json).toContain("The pendant");
  });

  test("home IR contains specs", () => {
    const json = JSON.stringify(homeIr);
    expect(json).toContain("2.5cm diameter, 1.5cm deep");
    expect(json).toContain("150 mAh, 10–14 hours");
    expect(json).toContain("AES-256-GCM");
  });

  test("home IR contains hardware capabilities", () => {
    const json = JSON.stringify(homeIr);
    expect(json).toContain("Capture everything");
    expect(json).toContain("Recall instantly");
    expect(json).toContain("Automate your work");
  });

  test("home IR contains CTA links", () => {
    const json = JSON.stringify(homeIr);
    expect(json).toContain("https://api.omi.tsc.hk/portal");
    expect(json).toContain("Open Omi");
    expect(json).toContain("Documentation");
  });

  test("architecture IR contains model tiers", () => {
    const json = JSON.stringify(architectureIr);
    expect(json).toContain("inception/mercury-2");
    expect(json).toContain("xiaomi/mimo-v2.5");
    expect(json).toContain("google/gemini-3.6-flash");
    expect(json).toContain("perplexity/sonar");
  });

  test("architecture IR contains section headings", () => {
    const json = JSON.stringify(architectureIr);
    expect(json).toContain("The request path");
    expect(json).toContain("Model tiers");
    expect(json).toContain("Data plane");
    expect(json).toContain("Memory");
    expect(json).toContain("Channels");
    expect(json).toContain("The approval gate");
    expect(json).toContain("FaceTime");
    expect(json).toContain("The pendant path");
  });

  test("api docs IR contains section headings", () => {
    const json = JSON.stringify(apiDocsIr);
    expect(json).toContain("The public API");
    expect(json).toContain("Contents");
    expect(json).toContain("1. Authentication");
    expect(json).toContain("5. MCP server");
  });

  test("api docs IR contains REST endpoints", () => {
    const json = JSON.stringify(apiDocsIr);
    expect(json).toContain("/api/v1/me");
    expect(json).toContain("/api/v1/memory/search");
    expect(json).toContain("/api/v1/currents");
    expect(json).toContain("/api/v1/facetime/calls");
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
    expect(head).toContain('/inter-latin-variable.woff2');
    expect(head).toContain('/geist-pixel-square.woff2');
  });

  test("buildHead includes enhancement scripts", () => {
    const head = buildHead("Title", "Desc", "/");
    expect(head).toContain('/main.js');
    expect(head).toContain('/mark.js');
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
  test("all three page paths are defined", () => {
    const paths = ["/", "/architecture", "/docs/api"];
    for (const p of paths) {
      expect(p).toBeTruthy();
    }
  });
});
