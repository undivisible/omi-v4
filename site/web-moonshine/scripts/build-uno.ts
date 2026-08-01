import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { createGenerator } from "unocss";
import config from "../uno.config";

const root = join(import.meta.dir, "..");

async function sources(dir: string): Promise<string[]> {
  const found: string[] = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) found.push(...(await sources(path)));
    else if (/\.(tsx|ts)$/.test(entry.name)) found.push(path);
  }
  return found;
}

const generator = await createGenerator(config);
const files = await sources(join(root, "src"));
/* Only className/class literals count: scanning raw source would mint
   utilities for every English word that happens to match a rule name. */
let markup = "";
for (const file of files) {
  const text = await Bun.file(file).text();
  for (const [, value] of text.matchAll(/class(?:Name)?="([^"]*)"/g)) {
    markup += ` ${value}`;
  }
}

const { css } = await generator.generate(markup, { preflights: true });
await Bun.write(join(root, "public", "uno.css"), css);

console.log(`build-uno: public/uno.css (${css.length} bytes)`);
