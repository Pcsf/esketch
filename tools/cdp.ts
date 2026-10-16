// Minimal Chrome DevTools Protocol client for the page checks: launches
// headless Chromium on a page with name resolution disabled and returns
// helpers to evaluate script and send trusted input.
import { resolve } from "path";

export async function openPage(url: string, extraArgs: string[] = []) {
  const port = 9333 + Math.floor(Math.random() * 500);
  const proc = Bun.spawn([process.env.CHROMIUM ?? "chromium", "--headless", "--disable-gpu", "--no-sandbox",
    "--window-size=1300,800", "--host-resolver-rules=MAP * ~NOTFOUND", `--remote-debugging-port=${port}`,
    `--user-data-dir=${resolve(`build/verify/profile-${port}`)}`, "--no-first-run", "--no-default-browser-check",
    "--disable-background-networking", "--disable-component-update", "--disable-sync", ...extraArgs, url],
    { stderr: "ignore", stdout: "ignore" });
  const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
  let target: any = null;
  for (let i = 0; i < 100 && !target; i++) {
    await sleep(200);
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t: any) => t.type === "page"); } catch {}
  }
  if (!target) { proc.kill(); throw new Error("could not reach Chromium"); }
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise(r => ws.addEventListener("open", r));
  let seq = 0; const waiting = new Map<number, (v: any) => void>();
  ws.addEventListener("message", (m: any) => {
    const d = JSON.parse(m.data);
    if (d.id && waiting.has(d.id)) { waiting.get(d.id)!(d.result); waiting.delete(d.id); }
  });
  const send = (method: string, params: any = {}) =>
    new Promise<any>(r => { const id = ++seq; waiting.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
  const evaluate = async (expr: string) =>
    (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }))?.result?.value;
  const close = async () => {
    send("Browser.close").catch(() => {});
    await Promise.race([proc.exited, sleep(5000)]);
    ws.close(); proc.kill();
  };
  return { send, evaluate, close, sleep };
}
