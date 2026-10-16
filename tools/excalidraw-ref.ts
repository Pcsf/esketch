// Renders .excalidraw files with real Excalidraw (@excalidraw/utils 0.1.5,
// exportToSvg) in headless Chromium and writes one SVG per input to OUT.
// Usage: bun tools/excalidraw-ref.ts OUT FILE...
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "fs";
import { basename, resolve } from "path";

const [out, ...files] = process.argv.slice(2);
const work = resolve("build/ref-work");
mkdirSync(work, { recursive: true });
mkdirSync(out, { recursive: true });
const bundle = `${work}/bundle.js`;
if (!existsSync(bundle)) {
  const r = await Bun.build({ entrypoints: [resolve("tools/excalidraw-ref-entry.ts")], outdir: work,
                              target: "browser", naming: "bundle.js" });
  if (!r.success) { console.error(r.logs); process.exit(1); }
}
const chromium = process.env.CHROMIUM ?? "chromium";
let ok = 0;
for (const f of files) {
  const data = readFileSync(f, "utf8");
  const page = `${work}/page.html`;
  writeFileSync(page, `<!doctype html><html><body><pre id="out">pending</pre>
<script type="module" src="bundle.js"></script>
<script type="module">
const data = ${data};
window.exportToSvg({ data: { elements: data.elements, appState: { ...(data.appState || {}), exportBackground: true }, files: data.files || {} },
                     config: { skipInliningFonts: true } })
  .then(svg => { document.getElementById("out").textContent = svg.outerHTML; })
  .catch(e => { document.getElementById("out").textContent = "ERR " + e; });
</script></body></html>`);
  const p = Bun.spawnSync([chromium, "--headless", "--disable-gpu", "--no-sandbox",
    "--allow-file-access-from-files", "--virtual-time-budget=20000", "--dump-dom", `file://${page}`], { stderr: "ignore" });
  const m = p.stdout.toString().match(/<pre id="out">([\s\S]*?)<\/pre>/);
  const svg = m ? m[1].replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&amp;/g, "&") : "";
  if (svg.startsWith("<svg")) { writeFileSync(`${out}/${basename(f, ".excalidraw")}.svg`, svg); ok++; }
  else console.error(`${basename(f)}: ${svg.slice(0, 120) || "no output"}`);
}
console.log(`excalidraw-ref: ${ok} of ${files.length} rendered`);
