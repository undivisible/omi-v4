# omi-web-moonshine

The front-facing website at `omi.tsc.hk`, built with
[moonshine](https://github.com/tschk/moonshine) — Bun serving React components
compiled to a Crepus IR, rendered to HTML by the Crepus moonshine renderer.

This replaces the previous Jaspr/Dart site in `site/`. The three routes are
preserved:

| Route | Source | What it is |
| --- | --- | --- |
| `/` | `src/ir.ts` (`homeIr`) | Hero, the hub, API & MCP, privacy, pricing |
| `/architecture` | `src/ir.ts` (`architectureIr`) | Request path, model tiers, data plane, pendant |
| `/docs/api` | `src/ir.ts` (`apiDocsIr`) | `docs/api.md`, rendered |

## Stack

- **Runtime:** Bun
- **UI:** React 19, compiled to a Crepus IR
- **Renderer:** `@tschk/crepus-moonshine` (`crepusRenderer`)
- **Server:** `@tschk/moonshine-deploy-bun` (`createBunServer`)
- **Static assets:** `public/` (fonts, stylesheets, the two enhancement
  modules `main.js` and `mark.js`)

`src/server.ts` maps each route to its Crepus IR, builds the `<head>` via
`src/head.ts`, and hands the render context to `crepusRenderer`. There is no
client bundle: the pages ship the two hand-written enhancement modules and
nothing else, matching the no-Java-by-default stance of the previous site.

## Commands

```
bun install          # install dependencies
bun run dev          # hot reload at http://localhost:3000
PORT=3012 bun run start   # production-style server on a custom port
bun test             # run the test suite
bunx tsc --noEmit    # type-check
```

The moonshine packages are pulled from `../../moonshine/packages/*` via
`file:` dependencies, so the `moonshine` checkout must sit beside `omi-v4`
under the same parent directory.

## Benchmarks

Local measurements, 10 sequential `curl` requests against a warm server on
`localhost`. The "before" is the Jaspr/Dart dev server (`jaspr serve -p 3011`,
static rendering mode); the "after" is this moonshine server
(`PORT=3012 bun run start`).

| Metric | Before (Jaspr/Dart) | After (moonshine) |
|--------|---------------------|-------------------|
| Avg response time | 7.0 ms | 2.6 ms |
| TTFB | 6.8 ms | 2.2 ms |
| HTML size | 7.9 KB | 34.3 KB |
| Stack | Dart + Jaspr | Bun + React + Crepus IR |

The moonshine server is roughly **2.7× faster** on TTFB and total response
time. The HTML payload is larger because the Crepus renderer emits the full
document inline (including the inlined favicon data URI and the complete
`<head>`), where Jaspr's static build deferred some of that to separate
assets. Both payloads are small in absolute terms and compress well under
brotli on the edge.
