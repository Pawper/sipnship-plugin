// Seeds a first, draft design/tokens.json from the mocks in design/mocks/:
// the colours, families, type sizes, radii and spacings they use, with how
// often each was seen. A person names, merges and drops from there; the
// draft is a starting point, never the finished look.
// Usage: node scripts/design/seed-tokens.mjs [--print]
//   (no flag) writes design/tokens.json when none exists, else
//             design/tokens.draft.json; never overwrites either
//   --print   writes the draft to stdout and nothing else
// Reads HTML files and the .py, .js, .mjs and .ts generators beside them.
// Exits 2 when design/mocks/ holds nothing to read.
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { newTally, collect, draftTokens, pairSides } from "./seed-lib.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const READ = /\.(html?|py|js|mjs|ts)$/i, SKIP = new Set(["node_modules", ".git", "__pycache__"]);

function walk(dir, out = []) {
  let names = [];
  try { names = readdirSync(dir); } catch { return out; }
  for (const n of names.sort()) {
    if (SKIP.has(n)) continue;
    const p = join(dir, n), s = statSync(p);
    if (s.isDirectory()) walk(p, out);
    else if (READ.test(n) && s.size < 5e6) out.push(p);
  }
  return out;
}

const files = walk(join(root, "design", "mocks"));
if (!files.length) {
  console.error("There are no mocks to read: design/mocks/ is missing or holds no HTML screens or generators.");
  process.exit(2);
}
const isScreen = (f) => /\.html?$/i.test(f);
const sides = pairSides(files.filter(isScreen).map((f) => basename(f)));
const tally = newTally();
tally.pairs = Object.values(sides).filter((s) => s === "dark").length;
for (const f of files) collect(readFileSync(f, "utf8"), tally, isScreen(f) ? sides[basename(f)] || null : null);
const draft = JSON.stringify(draftTokens(tally), null, 2) + "\n";

if (process.argv.includes("--print")) {
  process.stdout.write(draft);
} else {
  const tokens = join(root, "design", "tokens.json"), spare = join(root, "design", "tokens.draft.json");
  const target = existsSync(tokens) ? spare : tokens;
  if (existsSync(target)) {
    console.error("design/tokens.json and design/tokens.draft.json both exist; neither was changed. Move the draft aside to seed again.");
    process.exit(1);
  }
  writeFileSync(target, draft);
  console.log(`Wrote ${target === tokens ? "design/tokens.json" : "design/tokens.draft.json"} from ${files.length} files: a draft for a person to name, merge and trim.`);
}
