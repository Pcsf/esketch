// Uses the esketch page with trusted mouse input sent through the Chrome
// DevTools Protocol, as a person would: drags a shape, then presses Send to
// Emacs and checks the drawing reached the clipboard and the download
// directory.
import { resolve } from "path";
import { mkdirSync, rmSync, existsSync, readFileSync } from "fs";
import { openPage } from "./cdp";

const p = await openPage(`file://${resolve("build/verify/page.html")}`);
for (let i = 0; i < 100 && !(await p.evaluate("!!window.esketchApi")); i++) await p.sleep(200);
await p.sleep(800);
const before = await p.evaluate(`(() => { const s = esketchApi.getAppState(), e = esketchApi.getSceneElements().find(e => e.id === "ell1");
  return { x: e.x, y: e.y, cx: (e.x + e.width / 2 + s.scrollX) * s.zoom.value + s.offsetLeft, cy: (e.y + e.height / 2 + s.scrollY) * s.zoom.value + s.offsetTop }; })()`);
const mouse = (type: string, x: number, y: number, buttons: number) =>
  p.send("Input.dispatchMouseEvent", { type, x, y, button: "left", buttons, clickCount: 1 });
await mouse("mouseMoved", before.cx, before.cy, 0);
await mouse("mousePressed", before.cx, before.cy, 1);
for (let k = 1; k <= 8; k++) { await mouse("mouseMoved", before.cx + 5 * k, before.cy + 2.5 * k, 1); await p.sleep(30); }
await mouse("mouseReleased", before.cx + 40, before.cy + 20, 0);
await p.sleep(300);
const after = await p.evaluate(`(() => { const e = esketchApi.getSceneElements().find(e => e.id === "ell1"); return { x: e.x, y: e.y }; })()`);
const moved = [Math.round(after.x - before.x), Math.round(after.y - before.y)];
const dragOk = moved[0] === 40 && moved[1] === 20;
console.log(`${dragOk ? "ok  " : "FAIL"} drag with trusted mouse input moves the ellipse by (40, 20): got ${JSON.stringify(moved)}`);

const dl = resolve("build/verify/downloads");
rmSync(dl, { recursive: true, force: true }); mkdirSync(dl, { recursive: true });
await p.send("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: dl });
await p.send("Browser.grantPermissions", { permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"] });
const b = await p.evaluate(`(() => { const r = document.querySelector(".esketch-send").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
await mouse("mouseMoved", b.x, b.y, 0);
await mouse("mousePressed", b.x, b.y, 1);
await mouse("mouseReleased", b.x, b.y, 0);
const file = `${dl}/basic.excalidraw`;
for (let i = 0; i < 50 && !existsSync(file); i++) await p.sleep(100);
const saved = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : null;
const savedOk = saved?.type === "excalidraw" && saved.elements.find((e: any) => e.id === "ell1")?.x === after.x;
console.log(`${savedOk ? "ok  " : "FAIL"} Send to Emacs saved basic.excalidraw with the moved ellipse`);
const clip = await p.evaluate("navigator.clipboard.readText().catch(e => 'ERR ' + e)");
const clipOk = typeof clip === "string" && clip.includes('"type": "excalidraw"');
console.log(`${clipOk ? "ok  " : "FAIL"} Send to Emacs put the drawing on the clipboard`);
await p.close();
process.exit(dragOk && savedOk && clipOk ? 0 : 1);
