// For each .excalidraw file in DIR, writes to OUT what Excalidraw would save
// for it, JSON.stringify(JSON.parse(raw), null, 2), keeping a final newline
// if the source had one.
import { readdirSync, readFileSync, writeFileSync, mkdirSync } from "fs";
const [dir, out] = process.argv.slice(2);
mkdirSync(out, { recursive: true });
for (const f of readdirSync(dir).filter(f => f.endsWith(".excalidraw"))) {
  const raw = readFileSync(`${dir}/${f}`, "utf8");
  writeFileSync(`${out}/${f}`, JSON.stringify(JSON.parse(raw), null, 2) + (raw.endsWith("\n") ? "\n" : ""));
}
