// Opens the esketch page for test/data/basic.excalidraw in headless Chromium
// with name resolution disabled, drives it (tools/verify-harness.js), and
// checks: drawing loaded, Excalifont loaded, drawing/undo/redo/drag/zoom
// work, PNG and SVG export work, the Send to Emacs button exists, no page
// error, and no network request left the machine.  Writes the page's export
// to build/verify/export.excalidraw for the Emacs side of the round trip.
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { resolve } from "path";

const dir = resolve("build/verify");
mkdirSync(dir, { recursive: true });
const page = readFileSync(`${dir}/page.html`, "utf8");
const harness = readFileSync("tools/verify-harness.js", "utf8");
const i = page.lastIndexOf("</body>");
writeFileSync(`${dir}/driven.html`, page.slice(0, i) + `<script>${harness}</script>` + page.slice(i));
import { openPage } from "./cdp";
const p = await openPage(`file://${dir}/driven.html`, [`--log-net-log=${dir}/net.json`]);
let r: any = {};
for (let i = 0; i < 300; i++) {
  const t = await p.evaluate("document.getElementById('harness-result')?.textContent || ''");
  if (t && t !== "pending") { r = JSON.parse(t); break; }
  await p.sleep(200);
}
const shot = await p.send("Page.captureScreenshot", { format: "png" });
if (shot?.data) writeFileSync(`${dir}/page.png`, Buffer.from(shot.data, "base64"));
await p.close();

const net = readFileSync(`${dir}/net.json`, "utf8");
// Requests the page made carry a file:// network isolation key; Chromium's
// own background requests (account checks and the like) do not.
const netlog = JSON.parse(net);
const sources: Record<string, any> = {};
for (const e of netlog.events) Object.assign(sources[e.source.id] ||= {}, e.params || {});
const remote = Object.values(sources).filter((p: any) => /^(https?|wss?):/.test(p.url ?? ""));
const pageRequests = [...new Set(remote.filter((p: any) => String(p.network_isolation_key).startsWith("file://")).map((p: any) => p.url))];
const external = [...new Set(remote.map((p: any) => p.url))].filter(u => !pageRequests.includes(u));
const checks: [string, boolean][] = [
  ["drawing loaded (8 live elements)", r.initial === 8],
  ["Excalifont loaded from the page", Array.isArray(r.excalifont) && r.excalifont.includes("loaded")],
  ["rectangle drawn with the mouse, 120 x 90", r.afterRect === 9 && JSON.stringify(r.rectSize) === '["rectangle",120,90]'],
  [`freehand stroke drawn across the whole path (${JSON.stringify(r.freeSpan)})`, r.afterFree === 10 && JSON.stringify(r.freeSpan) === '["freedraw",100]'],
  ["Ctrl+Z undoes", r.afterUndo === 9],
  ["Ctrl+Shift+Z redoes", r.afterRedo === 10],
  ["Ctrl+wheel zooms in", Array.isArray(r.zoom) && r.zoom[1] > r.zoom[0]],
  ["SVG export works", r.svgLength > 1000],
  ["PNG export works", r.pngBytes > 1000],
  ["Send to Emacs button present", r.sendButton === true],
  ["no page errors", Array.isArray(r.errors) && r.errors.length === 0],
  ["the page made no network request but the planted probe",
   JSON.stringify(pageRequests) === '["https://planted.invalid/esketch-probe"]'],
];
for (const [what, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${what}`);
if (external.length) console.log("Chromium's own requests (not the page's):", external.slice(0, 5));
console.log("page requests:", JSON.stringify(pageRequests));
if (r.errors?.length) console.log("errors:", r.errors.slice(0, 5));
if (r.exported) writeFileSync(`${dir}/export.excalidraw`, r.exported);
process.exit(checks.every(([, ok]) => ok) ? 0 : 1);
