// Writes test/rough-cases.json: the real roughjs 4.6.4 generator run over a
// table of shape calls.  Each case records the call, its arguments and
// options, and for every set its type and the opsToPath string.  esketch's
// roughjs port is checked against this table.
//
// roughjs draws dot fills with Math.random, and falls back to it when the
// seed is 0.  Math.random is replaced here by a small generator restarted for
// every case, and the table records its parameters so the test can do the same.
import { writeFileSync } from "fs";
import rough from "roughjs";
import { Random } from "roughjs/bin/math.js";

const MATH_RANDOM = { multiplier: 16807, modulus: 2147483647, seed: 12345 };
let state = MATH_RANDOM.seed;
Math.random = () => {
  state = (state * MATH_RANDOM.multiplier) % MATH_RANDOM.modulus;
  return state / MATH_RANDOM.modulus;
};

type Opts = Record<string, unknown>;
interface Case { name: string; call: string; args: unknown[]; options: Opts }
const cases: Case[] = [];
const add = (name: string, call: string, args: unknown[], options: Opts = {}) =>
  cases.push({ name, call, args, options });

const styles = ["hachure", "cross-hatch", "zigzag", "solid", "dots", "dashed", "zigzag-line"];
const base = { seed: 1337, fill: "#a5d8ff", hachureGap: 6, fillWeight: 1.5 };
// Every dot is a drawn ellipse, so dot fills use a wide gap to keep the table small.
const withStyle = (s: string, extra: Opts = {}) =>
  ({ ...base, ...(s === "dots" ? { hachureGap: 26 } : {}), ...extra, fillStyle: s });

// line
add("line-default", "line", [10, 20, 210, 90], { seed: 1 });
for (const r of [0, 1, 2, 2.5])
  add(`line-roughness-${r}`, "line", [5, 5, 305, 155], { seed: 42, roughness: r });
add("line-long-over-500", "line", [0, 0, 700, 300], { seed: 7 });
add("line-mid-300", "line", [0, 0, 280, 120], { seed: 8 });
add("line-short-clamped-offset", "line", [0, 0, 6, 4], { seed: 9 });
add("line-zero-length", "line", [30, 30, 30, 30], { seed: 10 });
add("line-preserve-vertices", "line", [10, 10, 160, 40], { seed: 11, preserveVertices: true });
add("line-single-stroke", "line", [10, 10, 160, 40], { seed: 12, disableMultiStroke: true });
add("line-bowing-0-and-3", "line", [10, 10, 160, 40], { seed: 13, bowing: 3, maxRandomnessOffset: 4 });
add("line-bowing-zero", "line", [10, 10, 160, 40], { seed: 14, bowing: 0 });
add("line-huge-seed", "line", [0, 0, 100, 100], { seed: 2147483647 });
add("line-seed-beyond-int32", "line", [0, 0, 100, 100], { seed: 4294967301 });
add("line-fractional-coords", "line", [0.37, -12.5, 99.99, 61.125], { seed: 3, roughness: 1.3 });
add("line-seed-zero-math-random", "line", [0, 0, 100, 40], { seed: 0 });

// rectangle
for (const r of [0, 1, 2, 2.5])
  add(`rect-stroke-roughness-${r}`, "rectangle", [10, 10, 180, 90], { seed: 5, roughness: r });
for (const s of styles)
  add(`rect-fill-${s}`, "rectangle", [20, 30, 160, 100], withStyle(s));
for (const s of ["hachure", "cross-hatch", "zigzag", "dots", "dashed", "zigzag-line"])
  add(`rect-fill-${s}-roughness-0`, "rectangle", [20, 30, 160, 100], withStyle(s, { roughness: 0 }));
add("rect-fill-hachure-roughness-2.5", "rectangle", [20, 30, 160, 100], { ...base, roughness: 2.5 });
add("rect-fill-cross-hatch-roughness-2", "rectangle", [20, 30, 160, 100], { ...base, fillStyle: "cross-hatch", roughness: 2 });
add("rect-fill-hachure-angle-60", "rectangle", [0, 0, 120, 80], { ...base, hachureAngle: 60 });
add("rect-fill-hachure-angle-minus-90", "rectangle", [0, 0, 120, 80], { ...base, hachureAngle: -90 });
add("rect-fill-default-gap-stroke-3", "rectangle", [0, 0, 120, 80], { seed: 99, fill: "red", strokeWidth: 3 });
add("rect-fill-dots-default-weight", "rectangle", [0, 0, 60, 40], { seed: 99, fill: "red", fillStyle: "dots", strokeWidth: 4 });
add("rect-fill-dashed-offset-gap", "rectangle", [0, 0, 160, 80], { ...base, fillStyle: "dashed", dashOffset: 9, dashGap: 5 });
add("rect-fill-zigzag-line-offset", "rectangle", [0, 0, 160, 80], { ...base, fillStyle: "zigzag-line", zigzagOffset: 4 });
add("rect-fill-multistroke-fill-off", "rectangle", [0, 0, 120, 80], { ...base, disableMultiStrokeFill: true });
add("rect-fill-preserve-vertices", "rectangle", [0, 0, 120, 80], { ...base, preserveVertices: true });
add("rect-fill-solid-single-stroke", "rectangle", [0, 0, 120, 80], { ...base, fillStyle: "solid", disableMultiStroke: true });
add("rect-fill-stroke-none", "rectangle", [0, 0, 120, 80], { ...base, stroke: "none" });
add("rect-negative-size", "rectangle", [100, 100, -80, -50], { ...base });
add("rect-fill-seed-zero-math-random", "rectangle", [0, 0, 120, 80], { ...base, seed: 0 });
add("rect-fill-tiny-gap", "rectangle", [0, 0, 40, 30], { ...base, hachureGap: 0.05 });
add("rect-fill-max-randomness-5", "rectangle", [0, 0, 120, 80], { ...base, maxRandomnessOffset: 5, bowing: 2 });

// ellipse and circle
for (const r of [0, 1, 2, 2.5])
  add(`ellipse-stroke-roughness-${r}`, "ellipse", [100, 60, 160, 90], { seed: 21, roughness: r });
for (const s of styles)
  add(`ellipse-fill-${s}`, "ellipse", [100, 60, 160, 90], withStyle(s));
add("ellipse-fill-hachure-roughness-0", "ellipse", [100, 60, 160, 90], { ...base, roughness: 0 });
add("ellipse-fill-solid-roughness-0", "ellipse", [100, 60, 160, 90], { ...base, roughness: 0, fillStyle: "solid" });
add("ellipse-curve-fitting-1", "ellipse", [100, 60, 160, 90], { seed: 22, curveFitting: 1 });
add("ellipse-curve-fitting-0.5-steps-14", "ellipse", [100, 60, 160, 90], { seed: 23, curveFitting: 0.5, curveStepCount: 14 });
add("ellipse-single-stroke", "ellipse", [100, 60, 160, 90], { seed: 24, disableMultiStroke: true });
add("ellipse-large", "ellipse", [400, 300, 700, 400], { seed: 25 });
add("ellipse-seed-zero-math-random", "ellipse", [100, 60, 160, 90], { seed: 0 });
add("circle-plain", "circle", [50, 50, 80], { seed: 31 });
add("circle-fill-cross-hatch", "circle", [50, 50, 80], { ...base, fillStyle: "cross-hatch" });
add("circle-roughness-2.5", "circle", [50, 50, 80], { seed: 33, roughness: 2.5 });

// linearPath
add("linear-path-0-points", "linearPath", [[]], { seed: 41 });
add("linear-path-1-point", "linearPath", [[[10, 10]]], { seed: 41 });
add("linear-path-2-points", "linearPath", [[[10, 10], [90, 50]]], { seed: 41 });
add("linear-path-3-points", "linearPath", [[[10, 10], [90, 50], [150, 20]]], { seed: 41 });
add("linear-path-6-points", "linearPath", [[[0, 0], [50, 80], [100, 10], [150, 90], [200, 20], [260, 70]]], { seed: 42, roughness: 2 });
add("linear-path-preserve-vertices", "linearPath", [[[0, 0], [50, 80], [100, 10]]], { seed: 43, preserveVertices: true });

// polygon
const tri = [[10, 10], [150, 30], [60, 120]];
const concave = [[0, 0], [160, 0], [160, 100], [80, 40], [0, 100]];
add("polygon-triangle-stroke", "polygon", [tri], { seed: 51 });
for (const s of styles)
  add(`polygon-concave-fill-${s}`, "polygon", [concave], withStyle(s));
add("polygon-triangle-fill-roughness-0", "polygon", [tri], { ...base, roughness: 0 });
add("polygon-two-points", "polygon", [[[0, 0], [50, 50]]], { seed: 52, fill: "red" });

// curve
add("curve-2-points", "curve", [[[10, 10], [120, 70]]], { seed: 61 });
add("curve-3-points", "curve", [[[10, 10], [60, 80], [120, 40]]], { seed: 62 });
add("curve-4-points", "curve", [[[10, 10], [60, 80], [120, 40], [180, 90]]], { seed: 63 });
add("curve-6-points-roughness-2", "curve", [[[0, 0], [40, 60], [90, 10], [140, 70], [190, 20], [240, 80]]], { seed: 64, roughness: 2 });
add("curve-tightness-0.5", "curve", [[[10, 10], [60, 80], [120, 40], [180, 90]]], { seed: 65, curveTightness: 0.5 });
add("curve-single-stroke", "curve", [[[10, 10], [60, 80], [120, 40], [180, 90]]], { seed: 66, disableMultiStroke: true });
add("curve-roughness-0", "curve", [[[10, 10], [60, 80], [120, 40], [180, 90]]], { seed: 67, roughness: 0 });
const cpts = [[10, 10], [80, 90], [150, 20], [200, 100], [120, 150]];
for (const s of ["solid", "hachure", "cross-hatch", "zigzag", "dots", "dashed", "zigzag-line"])
  add(`curve-fill-${s}`, "curve", [cpts], withStyle(s));
add("curve-fill-two-points-no-fill", "curve", [[[10, 10], [120, 70]]], { ...base });

// path
const rr = (w: number, h: number, r: number) =>
  `M ${r} 0 L ${w - r} 0 Q ${w} 0, ${w} ${r} L ${w} ${h - r} Q ${w} ${h}, ${w - r} ${h} L ${r} ${h} Q 0 ${h}, 0 ${h - r} L 0 ${r} Q 0 0, ${r} 0`;
const dia = (w: number, h: number) => {
  const k = 0.18, cx = w / 2, cy = h / 2, dx = w * k * 0.4, dy = h * k * 0.4;
  return `M ${cx - dx} ${dy * 0.5} L ${w - dx * 0.5} ${cy - dy} C ${w} ${cy - dy * 0.3}, ${w} ${cy + dy * 0.3}, ${w - dx * 0.5} ${cy + dy} ` +
    `L ${cx + dx} ${h - dy * 0.5} C ${cx + dx * 0.3} ${h}, ${cx - dx * 0.3} ${h}, ${cx - dx} ${h - dy * 0.5} ` +
    `L ${dx * 0.5} ${cy + dy} C 0 ${cy + dy * 0.3}, 0 ${cy - dy * 0.3}, ${dx * 0.5} ${cy - dy} ` +
    `L ${cx - dx} ${dy * 0.5} C ${cx - dx * 0.3} 0, ${cx + dx * 0.3} 0, ${cx + dx} ${dy * 0.5}`;
};
add("path-round-rect-stroke", "path", [rr(200, 100, 16)], { seed: 71 });
add("path-round-rect-roughness-0", "path", [rr(200, 100, 16)], { seed: 71, roughness: 0 });
add("path-round-rect-roughness-2.5", "path", [rr(200, 100, 16)], { seed: 72, roughness: 2.5 });
add("path-round-rect-single-stroke", "path", [rr(200, 100, 16)], { seed: 73, disableMultiStroke: true });
add("path-round-rect-preserve-vertices", "path", [rr(200, 100, 16)], { seed: 74, preserveVertices: true });
for (const s of styles)
  add(`path-round-rect-fill-${s}`, "path", [rr(200, 100, 16)], withStyle(s));
add("path-round-rect-excalidraw-style", "path", [rr(240.5, 120.25, 24)], { seed: 1987, roughness: 1, bowing: 1, strokeWidth: 2, fill: "#ffec99", fillStyle: "hachure", hachureGap: 8, fillWeight: 1, preserveVertices: true, stroke: "#1e1e1e" });
add("path-diamond-stroke", "path", [dia(200, 140)], { seed: 81 });
add("path-diamond-fill-hachure", "path", [dia(200, 140)], { ...base });
add("path-diamond-fill-solid", "path", [dia(200, 140)], { ...base, fillStyle: "solid" });
add("path-diamond-fill-cross-hatch-roughness-2", "path", [dia(200, 140)], { ...base, fillStyle: "cross-hatch", roughness: 2 });
add("path-relative-commands", "path", ["m 10 10 l 80 0 l 0 60 h -80 v -60 z"], { seed: 91 });
add("path-relative-curves", "path", ["m 10 80 c 20 -60 60 -60 80 0 s 60 60 80 0 q 20 -40 40 0 t 40 0"], { seed: 92 });
add("path-absolute-hv", "path", ["M 10 10 H 110 V 70 H 10 Z"], { seed: 93 });
add("path-smooth-and-quad", "path", ["M 10 80 C 20 10 60 10 80 80 S 140 150 160 80 Q 180 20 200 80 T 240 80"], { seed: 94 });
add("path-implicit-lineto-and-lowercase-z", "path", ["M 10 10 80 10 80 60 10 60 z"], { seed: 95 });
add("path-no-leading-moveto", "path", ["L 50 50 L 90 10"], { seed: 96 });
add("path-numbers-compact", "path", ["M10,10L90,10-0.5.5 1e1-2L20 40Z"], { seed: 97 });
add("path-elliptical-arc", "path", ["M 10 80 A 40 30 0 0 1 90 80 A 40 30 30 1 0 10 80"], { seed: 98, preserveVertices: true });
add("path-arc-zero-radius", "path", ["M 10 10 A 0 0 0 0 1 90 10"], { seed: 98 });
add("path-two-subpaths-stroke", "path", ["M 10 10 L 60 10 L 60 60 Z M 100 10 L 150 10 L 150 60 Z"], { seed: 100 });
add("path-two-subpaths-solid", "path", ["M 10 10 L 60 10 L 60 60 Z M 100 10 L 150 10 L 150 60 Z"], { ...base, fillStyle: "solid" });
add("path-two-subpaths-hachure", "path", ["M 10 10 L 60 10 L 60 60 Z M 100 10 L 150 10 L 150 60 Z"], { ...base });
add("path-simplification-0.5", "path", [rr(200, 100, 16)], { seed: 101, simplification: 0.5 });
add("path-simplification-0.5-fill", "path", [rr(200, 100, 16)], { ...base, simplification: 0.5 });
add("path-fill-transparent-ignored", "path", [rr(100, 60, 10)], { seed: 102, fill: "transparent" });
add("path-stroke-none-fill-zigzag", "path", [rr(100, 60, 10)], { ...base, fillStyle: "zigzag", stroke: "none" });
add("path-newlines-and-detached-minus", "path", ["M 10 10\nL 90 10\nL 90 - 50"], { seed: 103 });
add("path-seed-zero-math-random", "path", [rr(100, 60, 10)], { ...base, seed: 0 });
add("path-empty", "path", [""], { seed: 104 });

const gen = rough.generator();
const out = cases.map(c => {
  state = MATH_RANDOM.seed;
  const drawable = (gen as any)[c.call](...c.args, { ...c.options });
  const sets = drawable.sets.map((s: any) => ({ type: s.type, d: gen.opsToPath(s) }));
  return { ...c, sets };
});

const randoms = [1, 2, 12345, 1987, 2147483647, 2147483648, 4294967301, 123456789012, -77]
  .map(seed => {
    const r = new Random(seed);
    return { seed, values: Array.from({ length: 12 }, () => r.next()) };
  });

writeFileSync(process.argv[2] ?? "test/rough-cases.json",
  JSON.stringify({ roughjs: "4.6.4", mathRandom: MATH_RANDOM, randoms, cases: out }, null, 1) + "\n");
console.log(`${out.length} cases`);
