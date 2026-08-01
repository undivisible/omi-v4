import { mkdir } from "node:fs/promises";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const entry = join(root, "client", "computer-stage.ts");
const outdir = join(root, "public");

await mkdir(outdir, { recursive: true });

const result = await Bun.build({
  entrypoints: [entry],
  outdir,
  target: "browser",
  minify: true,
  sourcemap: "none",
  naming: "computer-stage.js",
});

if (!result.success) {
  console.error(result.logs);
  process.exit(1);
}

console.log("build-client: public/computer-stage.js");
