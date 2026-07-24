# site

The front-facing website at `omi.tsc.hk`, built with [Jaspr](https://jaspr.site)
— Dart components, pre-rendered to static HTML.

Three pages:

| Route | Source | What it is |
| --- | --- | --- |
| `/` | `lib/pages/home.dart` | Hero, the hub, API & MCP, privacy, pricing |
| `/architecture` | `lib/pages/architecture.dart` | Request path, model tiers, data plane, pendant |
| `/docs/api` | `lib/pages/api_docs.dart` | `docs/api.md`, rendered |

## Commands

Both are run from `worker/`, so a deploy cannot ship a stale site:

```
bun run build:site   # build and copy into worker/public/
bun run dev:site     # hot reload at http://localhost:8080
bun run deploy       # build:site, then build:hub, then wrangler deploy
```

They shell out to `site/scripts/build.sh` and `site/scripts/serve.sh`, which
put the Dart SDK bundled with Flutter on `PATH` — the Homebrew `dart` shim
resolves outside an SDK directory and the Jaspr CLI refuses it.

One-time setup: `dart pub global activate jaspr_cli`.

## Where it builds to

`jaspr build` writes `site/build/jaspr/`, and `scripts/build.sh` rsyncs that
over `worker/public/`, which the Worker serves as static assets.

**`worker/public/` is generated output.** Everything in it comes from one of
two builds and nothing in it should be edited by hand:

- the site — this project, via `bun run build:site`
- `worker/public/hub/` — the Flutter web build, via `bun run build:hub`
  (already gitignored in `worker/.gitignore`)

The rsync passes `--exclude '/hub/'`, so the two builds do not clobber each
other and either can be re-run alone.

## No JavaScript

The pages ship the two hand-written enhancement modules in `web/` and nothing
else. There is deliberately **no `lib/main.client.dart`**: Jaspr injects its
client bundle into every generated page whenever a client entrypoint exists,
and removing it is what makes the built pages carry no Dart JavaScript at all.
No component is annotated `@client`.

Measured on this project, eager bundle, brotli, shipped on *every* page:

| Setup | Eager JS |
| --- | --- |
| No client entrypoint (what ships) | **0 B** |
| A client entrypoint, no `@client` components | 33 KB |
| One trivial `@client` island | 58 KB |
| `jaspr_flutter_embed` mounting the real Omi app | 131 KB |

The two modules in `web/` come to 2.5 KB brotli between them, and both are
additive: without either, every page still renders and every link still works.

## Why the hub is an iframe and not `jaspr_flutter_embed`

The hub is embedded as an iframe onto the standalone `/hub/` build produced by
`worker/scripts/build-hub.sh`, loaded on click. That build is compiled with
`--dart-define=OMI_DEMO=1`, which boots the real `OmiShell` against the seeded
in-process services in `app/lib/demo/`: seeded conversation history, currents,
meeting notes and memory, a persistent demo banner, and no network request of
any kind — no auth, no worker, no model. Surfaces that need the native hub
(capture, the pendant, transcription, computer use) show their real unavailable
state, because the demo hub refuses them exactly as the web target does. `jaspr_flutter_embed` was built
and measured first, and rejected for four reasons:

1. **It costs every page 131 KB of brotli-compressed JavaScript** — the table
   above. Deferred imports keep the Flutter framework itself out of the eager
   chunk, but dart2js hoists enough shared code into it to more than double the
   baseline, and Jaspr's client script is injected app-wide, so the
   architecture page and the API reference pay it too despite having nothing to
   hydrate. The iframe costs nothing until the reader clicks.
2. **`FlutterEmbedView` mounts a widget, and the hub's entry is a `main()`.**
   `app/lib/main.dart` initialises `AppServices` asynchronously, resolves the
   rewind runtime and only then calls `runApp`. Embedding means restating that
   bootstrap inside this project and keeping it in step with the app by hand.
3. **It drags the whole app into the site's dependency graph** — `rinf`,
   `universal_ble`, `mcumgr_flutter`, `flutter_secure_storage`, `record`, and a
   git-pinned `crepuscularity_flutter`. The marketing site should not stop
   building because a plugin or a private ref moved.
4. **The iframe is a real fault boundary.** The app's canvas, its exceptions
   and its sign-in state stay out of this document.

None of this changes what the reader downloads when they do click: the runtime
is ~4.5 MB over brotli either way. `jaspr_flutter_embed` changes how it is
mounted, not how much it weighs, and the click-to-load behaviour, the reserved
aspect ratio and the failure fallback are all preserved.

## The stylesheet

`web/styles.css` is the hand-authored stylesheet from the previous site, kept
as a stylesheet rather than transcribed into Dart `@css` rules. It is the
design's source of truth — the type ramp, the palette, the mark's motion
system — and re-expressing 1,100 lines of it in another syntax would only
introduce differences. Jaspr's job here is the markup.

Additions since the port are at the end of the file: the named measures that
replaced inline styles, and the API reference's prose styles.

## Where the API reference needs to land

`/docs/api` is generated here but belongs on `api.omi.tsc.hk`, alongside the
API and the portal. Until the domains are split it builds into
`worker/public/docs/api/index.html` with everything else and is reachable at
`omi.tsc.hk/docs/api`. Moving it is a routing change on the Worker's side, not
a change here: the page is a self-contained static file that needs
`/styles.css` and the three fonts served from the same origin.

`lib/components/shell.dart` holds `apiHost`, `portalUrl` and `apiKeysUrl` in
one place, so pointing the nav at the split domains is a one-line edit.
