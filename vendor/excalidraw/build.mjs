// One-time vendoring build: bundles Excalidraw + React + all deps into a single
// self-contained, offline JS file plus its CSS and font assets, written into the
// app's Resources so the per-app build only has to copy static files.
//
// Run:  cd vendor/excalidraw && npm install && npm run build
// (or via ../../vendor-excalidraw.sh from the repo root)

import * as esbuild from "esbuild";
import { cpSync, mkdirSync, rmSync, existsSync, copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const outDir = join(repoRoot, "FloatNote", "FloatNote", "Resources", "excalidraw");
const exDist = join(here, "node_modules", "@excalidraw", "excalidraw", "dist", "prod");

mkdirSync(outDir, { recursive: true });

// 1. Bundle the JS (React + Excalidraw + bridge) into one IIFE file.
await esbuild.build({
  entryPoints: [join(here, "main.jsx")],
  bundle: true,
  format: "iife",
  outfile: join(outDir, "bundle.js"),
  minify: true,
  sourcemap: false,
  target: ["safari16"],
  loader: { ".js": "jsx", ".jsx": "jsx" },
  define: {
    "process.env.NODE_ENV": '"production"',
    "process.env.IS_PREACT": '"false"',
    global: "window",
  },
  logLevel: "info",
});

// 2. Copy Excalidraw's stylesheet.
copyFileSync(join(exDist, "index.css"), join(outDir, "index.css"));

// 3. Copy font + runtime asset folders that Excalidraw fetches at runtime via
//    EXCALIDRAW_ASSET_PATH (set to "./" in main.jsx). These must sit next to
//    bundle.js. We copy them under the same relative layout the dist uses.
for (const folder of ["fonts"]) {
  const src = join(exDist, folder);
  if (existsSync(src)) {
    const dst = join(outDir, folder);
    rmSync(dst, { recursive: true, force: true });
    cpSync(src, dst, { recursive: true });
  }
}

console.log("Vendored Excalidraw ->", outDir);
