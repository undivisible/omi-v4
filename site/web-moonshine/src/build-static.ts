import { cp, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pages, renderPageHtml } from "./site-app";

const root = join(import.meta.dir, "..");
const publicDir = join(root, "public");
const staged = join(root, "build", "static");
const out = join(root, "..", "..", "cloud", "public");

async function main() {
  await mkdir(staged, { recursive: true });

  for (const page of Object.values(pages)) {
    const html = await renderPageHtml(page.path);
    if (!html) throw new Error(`failed to prerender ${page.path}`);
    const dest = join(staged, page.outFile);
    await mkdir(join(dest, ".."), { recursive: true });
    await writeFile(dest, html);
    console.log(`prerender ${page.path} → ${page.outFile}`);
  }

  await cp(publicDir, staged, { recursive: true });

  await mkdir(out, { recursive: true });

  // Replace generated site files without touching Flutter surfaces.
  const keep = new Set(["hub", "portal", "engine"]);
  const { readdir, rm } = await import("node:fs/promises");
  for (const entry of await readdir(out)) {
    if (keep.has(entry)) continue;
    await rm(join(out, entry), { recursive: true, force: true });
  }
  for (const entry of await readdir(staged)) {
    await cp(join(staged, entry), join(out, entry), { recursive: true });
  }

  console.log(`build-site: wrote ${out}`);
}

await main();
