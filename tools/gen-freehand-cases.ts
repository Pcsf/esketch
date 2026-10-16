// Writes test/freehand-cases.json: perfect-freehand 1.2.0 run for real, plus
// the way Excalidraw (packages/element/src/shape.ts, 4c37956b) turns a
// freedraw element into an SVG path.  Each row records the inputs, the
// getStrokePoints result, the getStroke outline and, for element rows, the
// final "d" string.  Run from the repository root: bun tools/gen-freehand-cases.ts
import { writeFileSync } from "fs";
import { getStroke, getStrokePoints } from "perfect-freehand";

type Pt = number[];
const easings: Record<string, (t: number) => number> = {
  sine: (t) => Math.sin((t * Math.PI) / 2),
  linear: (t) => t,
  quad: (t) => t * t,
};

const med = (A: Pt, B: Pt) => [(A[0] + B[0]) / 2, (A[1] + B[1]) / 2];
const TO_FIXED_PRECISION = /(\s?[A-Z]?,?-?[0-9]*\.[0-9]{0,2})(([0-9]|e|-)*)/g;
const getSvgPathFromStroke = (points: any[]) => {
  if (!points.length) return "";
  const max = points.length - 1;
  return points
    .reduce((acc: any[], point: any, i: number, arr: any[]) => {
      if (i === max) acc.push(point, med(point, arr[0]), "L", arr[0], "Z");
      else acc.push(point, med(point, arr[i + 1]));
      return acc;
    }, ["M", points[0], "Q"])
    .join(" ")
    .replace(TO_FIXED_PRECISION, "$1");
};

function rng(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function walk(seed: number, n: number, step: number, turn: number, round?: number) {
  const r = rng(seed);
  let x = r() * 800, y = r() * 600, a = r() * 2 * Math.PI;
  const pts: Pt[] = [];
  for (let i = 0; i < n; i++) {
    const px = round === undefined ? x : Math.round(x * 10 ** round) / 10 ** round;
    const py = round === undefined ? y : Math.round(y * 10 ** round) / 10 ** round;
    pts.push([px, py]);
    a += (r() - 0.5) * turn;
    const s = step * (0.2 + r() * 1.8);
    x += Math.cos(a) * s;
    y += Math.sin(a) * s;
  }
  const origin = pts[0];
  return pts.map(([px, py]) => [px - origin[0], py - origin[1]]);
}

function pressures(seed: number, n: number) {
  const r = rng(seed);
  return Array.from({ length: n }, () => 0.1 + r() * 0.9);
}

const cases: any[] = [];

function addElement(name: string, element: any) {
  const simulate: boolean = element.simulatePressure;
  const inputPoints = simulate
    ? element.points
    : element.points.length
    ? element.points.map(([x, y]: Pt, i: number) => [x, y, element.pressures[i]])
    : [[0, 0, 0.5]];
  const options = {
    simulatePressure: simulate,
    size: element.strokeWidth * 4.25,
    thinning: 0.6,
    smoothing: 0.5,
    streamline: element.strokeOptions?.streamline ?? 0.5,
    easing: "sine",
    last: true,
  };
  const call = { ...options, easing: easings.sine };
  const outline = getStroke(inputPoints, call);
  const strokePoints = getStrokePoints(inputPoints, call);
  cases.push({
    name,
    element,
    inputPoints,
    options,
    strokePoints: strokePoints.map((p) => ({
      point: p.point, pressure: p.pressure, vector: p.vector,
      distance: p.distance, runningLength: p.runningLength,
    })),
    outline,
    d: getSvgPathFromStroke(outline),
  });
}

function addLibrary(name: string, inputPoints: Pt[], options: any) {
  const call: any = { ...options };
  if (typeof options.easing === "string") call.easing = easings[options.easing];
  for (const k of ["start", "end"]) {
    if (options[k] && typeof options[k].easing === "string")
      call[k] = { ...options[k], easing: easings[options[k].easing] };
  }
  cases.push({
    name,
    inputPoints,
    options,
    strokePoints: getStrokePoints(inputPoints, call).map((p) => ({
      point: p.point, pressure: p.pressure, vector: p.vector,
      distance: p.distance, runningLength: p.runningLength,
    })),
    outline: getStroke(inputPoints, call),
  });
}

function el(points: Pt[], simulatePressure: boolean, strokeWidth: number, seed = 1, strokeOptions?: any) {
  const e: any = {
    points,
    pressures: simulatePressure ? [] : pressures(seed, points.length),
    simulatePressure,
    strokeWidth,
  };
  if (strokeOptions) e.strokeOptions = strokeOptions;
  return e;
}

// element rows
addElement("empty, simulated", el([], true, 2));
addElement("empty, real pressure", el([], false, 2));
addElement("one point, simulated", el([[0, 0]], true, 2));
addElement("one point, real pressure", el([[0, 0]], false, 2, 3));
addElement("two points, simulated", el([[0, 0], [30, 12.5]], true, 2));
addElement("two points, real pressure", el([[0, 0], [30, 12.5]], false, 4, 5));
addElement("two identical points", el([[0, 0], [0, 0]], true, 2));
addElement("three identical points", el([[0, 0], [0, 0], [0, 0]], false, 2, 2));
addElement("short 1 px, sim", el([[0, 0], [0.5, 0.5], [1, 0.2]], true, 1));
addElement("short 2 px, real", el([[0, 0], [1, 0.3], [2, 1]], false, 2, 7));
addElement("short 2.5 px, 4 wide", el([[0, 0], [0.7, 0.1], [1.4, 0.3], [2.5, 0.2]], true, 4));
addElement("tiny jitter", el([[0, 0], [0.01, 0.02], [0.02, 0.01], [0.015, 0.03]], false, 2, 9));
addElement("horizontal line", el(Array.from({ length: 30 }, (_, i) => [i * 4, 0]), true, 2));
addElement("vertical line, real", el(Array.from({ length: 30 }, (_, i) => [0, i * 3.5]), false, 2, 11));
addElement("reversal cusp", el([[0, 0], [20, 0], [40, 0], [20, 1], [0, 2], [-20, 3]], true, 2));
addElement("zigzag sharp corners", el(Array.from({ length: 14 }, (_, i) => [i * 6, i % 2 ? 30 : 0]), false, 2, 13));
addElement("closed circle", el(Array.from({ length: 25 }, (_, i) => [50 * Math.cos(i / 24 * 2 * Math.PI) - 50, 50 * Math.sin(i / 24 * 2 * Math.PI)]), true, 2));
addElement("large coordinates", el(walk(21, 40, 40, 1.2).map(([x, y]) => [x * 100, y * 100]), true, 2));
addElement("negative coordinates", el(walk(22, 30, 6, 1.0).map(([x, y]) => [x - 400, y - 500]), false, 2, 23));
for (const [i, w] of [1, 2, 4].entries()) {
  for (const sim of [true, false]) {
    const seed = 100 + i * 10 + (sim ? 0 : 5);
    addElement(`walk n=30 width ${w} ${sim ? "sim" : "pressures"}`, el(walk(seed, 30, 5, 0.9), sim, w, seed + 1));
  }
}
addElement("walk n=40, sim", el(walk(200, 40, 3, 0.6), true, 2));
addElement("walk n=40, pressures", el(walk(201, 40, 3, 0.6), false, 4, 202));
addElement("walk 2-decimal rounded", el(walk(210, 30, 4, 1.0, 2), true, 2));
addElement("walk 0-decimal rounded", el(walk(211, 30, 4, 1.0, 0), false, 1, 212));
addElement("streamline 0", el(walk(220, 30, 5, 0.9), true, 2, 1, { streamline: 0 }));
addElement("streamline 0.9", el(walk(221, 30, 5, 0.9), false, 2, 222, { streamline: 0.9 }));
addElement("streamline 1", el(walk(222, 30, 5, 0.9), true, 4, 1, { streamline: 1 }));
addElement("strokeOptions without streamline", el(walk(223, 40, 5, 0.9), true, 2, 1, { other: 1 }));
addElement("fast curvy strokes", el(walk(230, 30, 25, 2.5), true, 2));
addElement("short pressured stroke", el([[0, 0], [10, 3], [20, 5], [30, 9], [40, 9]].map((p) => p), false, 2, 1));

// library rows: options the Excalidraw call never uses
const lw = walk(300, 30, 5, 0.9);
const lp = lw.map(([x, y], i) => [x, y, pressures(301, 30)[i]]);
addLibrary("lib defaults", lw, {});
addLibrary("lib defaults, last", lw, { last: true });
addLibrary("lib thinning 0", lw, { size: 8, thinning: 0, last: true });
addLibrary("lib negative thinning, pressures", lp, { size: 12, thinning: -0.5, simulatePressure: false });
addLibrary("lib linear easing", lw, { size: 10, thinning: 0.7, easing: "quad" });
addLibrary("lib start taper number", lw, { size: 8, start: { taper: 40 } });
addLibrary("lib end taper true", lw, { size: 8, end: { taper: true }, last: true });
addLibrary("lib both tapers eased", lw, { size: 8, start: { taper: 30, easing: "linear" }, end: { taper: 30, easing: "quad" }, last: true });
addLibrary("lib flat caps", lw, { size: 8, start: { cap: false }, end: { cap: false } });
addLibrary("lib taper false", lw, { size: 8, start: { taper: false }, end: { taper: false } });
addLibrary("lib one point tapered", [[5, 5]], { size: 8, start: { taper: 10 } });
addLibrary("lib one point tapered, last", [[5, 5]], { size: 8, start: { taper: 10 }, last: true });
addLibrary("lib size 0", lw, { size: 0 });
const cusp = (pts: Pt[]) => addLibrary("lib sharp-corner flag " + pts.length, pts,
  { size: 8.5, thinning: 0.6, easing: "linear", last: true });
cusp([[0.0,0.0],[12.5,19.1],[6.2,40.9],[19.4,44.3],[5.5,55.3],[-6.9,46.1],[14.2,44.7],[16.0,48.5],[13.3,52.1],[21.1,62.6],[11.2,65.5],[3.4,86.1],[-4.5,95.0],[-13.5,98.4],[-7.0,88.0],[15.4,80.3],[10.5,71.5],[14.3,73.5],[28.5,87.0],[21.8,91.2],[19.2,87.7]]);
cusp([[0.0,0.0],[8.8,2.5],[21.5,4.3],[34.7,11.6],[25.9,10.8],[39.8,-0.6],[56.1,-13.3],[58.1,-27.7],[46.9,-7.2],[41.4,-10.9],[20.3,-17.3],[24.3,-18.5],[29.6,-15.9]]);
addLibrary("lib empty", [], {});
addLibrary("lib smoothing 0", lw, { size: 10, smoothing: 0 });

writeFileSync(process.argv[2] ?? "test/freehand-cases.json", "[\n" + cases.map((c) => JSON.stringify(c)).join(",\n") + "\n]\n");
console.log(`${cases.length} cases`);
