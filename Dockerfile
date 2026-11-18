# syntax=docker/dockerfile:1

FROM oven/bun:1.4.4 AS bun-runtime

FROM node:22-bookworm-slim AS base
WORKDIR /app
COPY --from=bun-runtime /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s /usr/local/bin/bun /usr/local/bin/bunx
ENV ASTRO_TELEMETRY_DISABLED=1

FROM base AS build
COPY . .
RUN rm -rf node_modules dist .astro

# Repair this repository inside the image; no separate GitHub edits needed.
RUN bun run - <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";

for (const file of ["scramjet.all.js", "scramjet.wasm.wasm"]) {
  if (!existsSync(`public/assets/scramjet/${file}`)) {
    throw new Error(`Missing bundled Scramjet file: ${file}`);
  }
}

const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const lock = Bun.JSONC.parse(readFileSync("bun.lock", "utf8"));

// The browser files are bundled already; remove the unused, broken download.
delete pkg.dependencies["@mercuryworkshop/scramjet"];
delete lock.packages["@mercuryworkshop/scramjet"];

// Use the React adapter version already recorded in this project's lockfile.
const adapter = "@astrojs/react";
const resolved = lock.packages[adapter][0];
if (!resolved.startsWith(`${adapter}@`)) {
  throw new Error("Unexpected React adapter lockfile entry");
}
pkg.dependencies[adapter] = resolved.slice(adapter.length + 1);
lock.workspaces[""].dependencies = pkg.dependencies;
lock.workspaces[""].devDependencies = pkg.devDependencies;

writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
writeFileSync("bun.lock", JSON.stringify(lock, null, 2) + "\n");

// Make the custom server reachable by Fly and fix the pre-build import check.
let server = readFileSync("index.ts", "utf8");
server = server.replace(
  /app\.listen\(\{\s*port(?:,\s*host)?\s*\}/,
  'app.listen({ port, host: process.env.HOST || "0.0.0.0" }'
);
server = server.replace(
  'import("./dist/server/entry.mjs")',
  'import(new URL("./dist/server/entry.mjs", import.meta.url).href)'
);
if (!server.includes('app.listen({ port, host: process.env.HOST || "0.0.0.0" }')) {
  throw new Error("Unexpected index.ts layout: listener patch not applied");
}
writeFileSync("index.ts", server);
JS

# Include build-time dependencies; retain the project's typecheck and build.
RUN bun install --frozen-lockfile
RUN npm run build
RUN test -s dist/server/entry.mjs \
    && test -s dist/client/assets/scramjet/scramjet.all.js \
    && test -s dist/client/assets/scramjet/scramjet.wasm.wasm

FROM base AS runtime
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8080 \
    FIRST=false
COPY --from=build --chown=node:node /app/ ./
USER node
EXPOSE 8080
CMD ["bun", "run", "index.ts"]