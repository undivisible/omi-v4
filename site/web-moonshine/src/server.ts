import { join } from "node:path";
import { createBunServer } from "@tschk/moonshine-deploy-bun";
import { handlePageRequest } from "./site-app";

const publicDir = join(import.meta.dir, "..", "public");

const server = createBunServer({
  fetch: handlePageRequest,
  port: Number(process.env.PORT) || 3000,
  staticDir: publicDir,
});

console.log(`omi moonshine → ${server.url.origin}`);
