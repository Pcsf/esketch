// Writes test/render-cases.json: rows of [x, digits, String(+x.toFixed(digits))],
// how roughjs prints path numbers for Excalidraw's SVG export.
import { writeFileSync } from "fs";
const xs = [0, -0, 1, 0.125, -0.125, 0.375, 1.005, 2.675, 1.455, 0.5, 1.5, 2.5, -2.5,
  123.456, 99.995, 99.994999, 1e-7, -1e-7, 1234567.891, 0.045, 0.055, 0.015, 8.345,
  1e20, 3e21, 580.0000000000001, -0.011448953630490633, 33.33333333333333];
const rows: [number, number, string][] = [];
for (const x of xs) for (const d of [0, 1, 2, 3]) rows.push([x, d, String(+x.toFixed(d))]);
let seed = 12345;
const rnd = () => ((seed = (Math.imul(seed, 1103515245) + 12345) | 0) >>> 0) / 4294967296;
for (let i = 0; i < 300; i++) {
  const x = (rnd() - 0.5) * Math.pow(10, Math.floor(rnd() * 8) - 2);
  rows.push([x, 2, String(+x.toFixed(2))]);
  const t = Math.round(x * 1000) / 1000 + 0.005 * (rnd() < 0.5 ? 1 : -1);
  rows.push([t, 2, String(+t.toFixed(2))]);
}
writeFileSync("test/render-cases.json", JSON.stringify(rows) + "\n");
