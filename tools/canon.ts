// Rewrites each named file as JSON.stringify(JSON.parse(raw), null, 2), the
// way Excalidraw saves, so hand-written fixtures are canonical.
import { readFileSync, writeFileSync } from "fs";
for (const f of process.argv.slice(2))
  writeFileSync(f, JSON.stringify(JSON.parse(readFileSync(f, "utf8")), null, 2));
