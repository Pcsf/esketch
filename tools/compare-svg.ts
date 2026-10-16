// Compares the path data of two SVG files drawn from the same document:
// esketch's and real Excalidraw's.  Paths are taken in document order and
// numbers compared within 0.011, the 2-decimal rounding of the export.
// Exit 1 on any difference.
const strip = (s: string) => s.replace(/<g class="esketch-text"[^>]*>.*?<\/g>/g, "");
const [a, b] = process.argv.slice(2).map(f => strip(require("fs").readFileSync(f, "utf8")));
const paths = (s: string) => [...s.matchAll(/<path [^>]*?d="([^"]*)"/g)].map(m => m[1]);
const pa = paths(a), pb = paths(b);
let bad = 0;
if (pa.length !== pb.length) { console.log(`path count ${pa.length} vs ${pb.length}`); bad++; }
for (let i = 0; i < Math.min(pa.length, pb.length); i++) {
  const ta = pa[i].split(/[\s,]+/), tb = pb[i].split(/[\s,]+/);
  const same = ta.length === tb.length && ta.every((t, j) => {
    const x = parseFloat(t.replace(/^[A-Za-z]/, "")), y = parseFloat(tb[j].replace(/^[A-Za-z]/, ""));
    return t.replace(/[-0-9.e]/g, "") === tb[j].replace(/[-0-9.e]/g, "") &&
      (isNaN(x) ? t === tb[j] : Math.abs(x - y) <= 0.011);
  });
  if (!same) { bad++; console.log(`path ${i} differs:\n  esketch    ${pa[i].slice(0, 160)}\n  excalidraw ${pb[i].slice(0, 160)}`); }
}
console.log(`${Math.min(pa.length, pb.length)} paths compared, ${bad} differ`);
process.exit(bad ? 1 : 0);
