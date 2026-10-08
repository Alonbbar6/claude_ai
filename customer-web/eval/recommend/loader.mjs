// Module hooks so plain Node can import the app's TypeScript (lib/recommend.ts and what it pulls in)
// without a bundler. Node 24 strips types natively; this adds the three things Next normally provides:
//   - "@/x" -> <customer-web>/x
//   - extensionless relative imports -> .ts / .tsx / /index.ts
//   - JSON imports without `with { type: "json" }`
// Run with `node -C react-server --import ./eval/recommend/register.mjs ...` so the `server-only`
// marker resolves to its empty build (the same export condition Next uses on the server).
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolvePath(dirname(fileURLToPath(import.meta.url)), "..", "..");
const TRY = ["", ".ts", ".tsx", ".mts", "/index.ts", "/index.tsx"];

export async function resolve(specifier, context, next) {
  let spec = specifier;
  if (spec.startsWith("@/")) spec = pathToFileURL(join(ROOT, spec.slice(2))).href;
  const relative = spec.startsWith("./") || spec.startsWith("../");
  if (relative || spec.startsWith("file:")) {
    const base = relative && context.parentURL ? fileURLToPath(new URL(spec, context.parentURL)) : spec.startsWith("file:") ? fileURLToPath(spec) : spec;
    for (const ext of TRY) {
      const p = base + ext;
      if (existsSync(p) && !p.endsWith("/")) {
        try { if (readFileSync(p).length >= 0 && !isDir(p)) return { url: pathToFileURL(p).href, shortCircuit: true }; } catch {}
      }
    }
  }
  return next(spec, context);
}

function isDir(p) {
  try { return readFileSync(p) && false; } catch (e) { return e?.code === "EISDIR"; }
}

export async function load(url, context, next) {
  if (url.endsWith(".json") && url.startsWith("file:") && context.importAttributes?.type !== "json") {
    const text = readFileSync(fileURLToPath(url), "utf8");
    JSON.parse(text); // fail early on a malformed file
    return { format: "module", source: `export default ${text};`, shortCircuit: true };
  }
  return next(url, context);
}
