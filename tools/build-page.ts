// Builds assets/esketch-page.html: Excalidraw 0.18.1 (MIT) with React, its
// CSS and every font except the CJK one, all inlined into one file that runs
// from file:// with no network.  Emacs fills in the two placeholders.
import { readFileSync, writeFileSync, readdirSync, statSync, mkdirSync } from "fs";
import { join, resolve } from "path";

const r = await Bun.build({
  entrypoints: [resolve("tools/page/entry.tsx")], target: "browser", minify: true,
  conditions: ["production"],
  define: { "process.env.NODE_ENV": '"production"' },
});
if (!r.success) { console.error(r.logs); process.exit(1); }
let js = "", css = "";
for (const o of r.outputs) {
  if (o.path.endsWith(".js")) js = await o.text();
  else if (o.path.endsWith(".css")) css = await o.text();
}
// The bundler inlines __dirname as this machine's absolute path; keep it out of
// the page.
js = js.split(resolve(".") + "/").join("./");
const fontDir = resolve("tools/node_modules/@excalidraw/excalidraw/dist/prod/fonts");
const fonts: Record<string, string> = {};
for (const fam of readdirSync(fontDir).filter(f => f !== "Xiaolai"))
  for (const f of readdirSync(join(fontDir, fam)).filter(f => f.endsWith(".woff2")))
    fonts[f] = "data:font/woff2;base64," + readFileSync(join(fontDir, fam, f)).toString("base64");
const html = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>esketch</title>
<!-- Excalidraw (https://github.com/excalidraw/excalidraw), MIT License, Copyright (c) 2020 Excalidraw.
     Fonts: SIL Open Font License 1.1.  Bundled by esketch tools/build-page.ts. -->
<style>html,body,#root{margin:0;height:100%}${css}</style></head>
<body><div id="root"></div>
<script type="text/plain" id="esketch-name">__ESKETCH_NAME__</script>
<script type="application/json" id="esketch-data">__ESKETCH_DATA__</script>
<script>window.ESKETCH_FONTS=${JSON.stringify(fonts)};</script>
<script type="module">${js.replace(/<\/script/gi, "<\\/script")}</script>
</body></html>
`;
mkdirSync("assets", { recursive: true });
writeFileSync("assets/esketch-page.html", html);
console.log(`assets/esketch-page.html: ${(statSync("assets/esketch-page.html").size / 1e6).toFixed(2)} MB, ${Object.keys(fonts).length} fonts`);
