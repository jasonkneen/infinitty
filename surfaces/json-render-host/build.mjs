// Builds the self-contained json-render host page shipped in the app bundle:
// esbuild bundles src/main.jsx (React + @json-render/react + the component
// registry), then the result is inlined into template.html and written to
// Sources/InfinittyKit/Resources/Surfaces/json-render-host.html.
//
// Regenerate with: npm run build   (from surfaces/json-render-host)
import { build } from "esbuild";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(
  here, "../../Sources/InfinittyKit/Resources/Surfaces/json-render-host.html");

const result = await build({
  entryPoints: [join(here, "src/main.jsx")],
  bundle: true,
  minify: true,
  format: "iife",
  jsx: "automatic",
  // The page runs in WKWebView on the user's macOS; esbuild's default esnext
  // output can use syntax older system WebKits fail to parse ("Script error
  // @0:0" with an empty page). safari16 keeps the output broadly parseable.
  target: "safari16",
  define: { "process.env.NODE_ENV": '"production"' },
  write: false,
  logLevel: "warning",
});

const bundle = ("try{" + result.outputFiles[0].text
  + "}catch(e){(window.__errors=window.__errors||[]).push('runtime: '+(e&&e.stack||e));}")
  // A literal "</script>" inside the JS would terminate the inline tag.
  .replaceAll("</script>", "<\\/script>");
const template = readFileSync(join(here, "template.html"), "utf8");
if (!template.includes("/*__BUNDLE__*/")) {
  throw new Error("template.html is missing the /*__BUNDLE__*/ marker");
}
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, template.replace("/*__BUNDLE__*/", () => bundle));
console.log("wrote", out, `(${(bundle.length / 1024).toFixed(0)} KiB js)`);
