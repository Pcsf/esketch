// Loads a drawing esketch wrote into the esketch page (Excalidraw 0.18.1) and
// checks that Excalidraw's load-time repair kept every element, every arrow
// binding and every label as esketch wrote them.
import { resolve } from "path";
import { readFileSync } from "fs";
import { openPage } from "./cdp";

const [pagePath, drawingPath] = process.argv.slice(2);
const orig = JSON.parse(readFileSync(drawingPath, "utf8")).elements.filter((e: any) => !e.isDeleted);
const p = await openPage(`file://${resolve(pagePath)}`);
for (let i = 0; i < 100 && !(await p.evaluate("!!window.esketchApi")); i++) await p.sleep(200);
await p.sleep(800);
const loaded = await p.evaluate("JSON.stringify(esketchApi.getSceneElements())").then((s: string) => JSON.parse(s));
await p.close();
const byId = new Map(loaded.map((e: any) => [e.id, e]));
const problems: string[] = [];
for (const e of orig) {
  const l: any = byId.get(e.id);
  if (!l) { problems.push(`${e.id} (${e.type}) dropped`); continue; }
  if (l.type !== e.type) problems.push(`${e.id} type ${e.type} -> ${l.type}`);
  for (const k of ["startBinding", "endBinding"])
    if ((e[k]?.elementId ?? null) !== (l[k]?.elementId ?? null)) problems.push(`${e.id} ${k} ${e[k]?.elementId} -> ${l[k]?.elementId}`);
  if ((e.containerId ?? null) !== (l.containerId ?? null)) problems.push(`${e.id} containerId changed`);
  const ids = (x: any) => (x.boundElements ?? []).map((b: any) => b.id).sort().join(",");
  if (ids(e) !== ids(l)) problems.push(`${e.id} boundElements ${ids(e)} -> ${ids(l)}`);
  if (e.type === "text" && l.text !== e.text) problems.push(`${e.id} text changed`);
}
for (const pr of problems) console.log("  " + pr);
const ok = problems.length === 0 && loaded.length === orig.length;
console.log(`${ok ? "ok  " : "FAIL"} Excalidraw kept all ${orig.length} elements, their bindings and labels as esketch wrote them`);
process.exit(ok ? 0 : 1);
