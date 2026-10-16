// Drives the esketch page with real DOM events once Excalidraw is up and
// writes what happened, as JSON, into the harness-result element.
(function () {
  const out = { errors: [] };
  window.addEventListener("error", e => out.errors.push(String(e.message)));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const live = () => esketchApi.getSceneElements().length;
  const canvas = () => document.querySelector("canvas.excalidraw__canvas.interactive");
  const view = (x, y) => { const s = esketchApi.getAppState(); return [(x + s.scrollX) * s.zoom.value + s.offsetLeft, (y + s.scrollY) * s.zoom.value + s.offsetTop]; };
  const ptr = (type, x, y, buttons) => canvas().dispatchEvent(new PointerEvent(type,
    location.hash.includes("plain")
      ? { bubbles: true, cancelable: true, pointerId: 1, pointerType: "mouse", clientX: x, clientY: y }
      : { bubbles: true, cancelable: true, pointerId: 1, pointerType: "mouse", isPrimary: true, clientX: x, clientY: y, button: 0, buttons }));
  async function drag(points) {
    ptr("pointerdown", ...points[0], 1); await sleep(30);
    for (const p of points.slice(1)) { ptr("pointermove", ...p, 1); await sleep(40); }
    const last = points[points.length - 1];
    ptr("pointerup", ...last, 0); await sleep(60);
  }
  const key = (k, opts) => (document.querySelector(".excalidraw") || document).dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts }));
  async function run() {
    while (!window.esketchApi || !canvas()) await sleep(50);
    await sleep(800);
    await document.fonts.ready;
    out.initial = live();
    out.excalifont = [...document.fonts].filter(f => f.family.replace(/"/g, "") === "Excalifont").map(f => f.status);
    esketchApi.setActiveTool({ type: "rectangle" }); await sleep(30);
    await drag([[700, 450], [760, 500], [820, 540]]);
    out.afterRect = live();
    { const els = esketchApi.getSceneElements(); const n = els[els.length - 1]; out.rectSize = [n.type, Math.round(n.width), Math.round(n.height)]; }
    esketchApi.setActiveTool({ type: "freedraw" }); await sleep(30);
    await drag([[300, 600], [320, 610], [345, 625], [370, 615], [400, 630]]);
    out.afterFree = live();
    { const els = esketchApi.getSceneElements(); const f = els[els.length - 1]; out.freePoints = f.points.length; out.freeSpan = [f.type, Math.round(f.width)]; }
    key("z", { code: "KeyZ", ctrlKey: true }); await sleep(80);
    out.afterUndo = live();
    key("Z", { code: "KeyZ", ctrlKey: true, shiftKey: true }); await sleep(80);
    out.afterRedo = live();
    const z0 = esketchApi.getAppState().zoom.value;
    canvas().dispatchEvent(new WheelEvent("wheel", { bubbles: true, cancelable: true, ctrlKey: true, deltaY: -100, clientX: 500, clientY: 300 }));
    await sleep(100);
    out.zoom = [z0, esketchApi.getAppState().zoom.value];
    out.sendButton = !!document.querySelector(".esketch-send");
    out.svgLength = (await esketchSvg()).length;
    out.pngBytes = await esketchPng();
    try { await fetch("https://planted.invalid/esketch-probe"); } catch (e) { /* expected: the network is cut */ }
    out.exported = esketchExport();
    document.getElementById("harness-result").textContent = JSON.stringify(out);
  }
  const pre = document.createElement("pre"); pre.id = "harness-result"; pre.textContent = "pending";
  document.addEventListener("DOMContentLoaded", () => document.body.appendChild(pre));
  run().catch(e => { out.errors.push("harness: " + e); document.getElementById("harness-result").textContent = JSON.stringify(out); });
})();
