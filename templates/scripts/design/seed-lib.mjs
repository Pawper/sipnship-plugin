// The pure part of seed-tokens.mjs: reading a look out of text and turning
// the counts into a draft tokens file. No file system here, so tests import it.

const PROPS = "background-color|background|color|border-color|border|fill|stroke|font-family|font-size|font-weight|letter-spacing|line-height|border-radius|text-transform|padding(?:-top|-right|-bottom|-left)?|margin(?:-top|-right|-bottom|-left)?|gap|row-gap|column-gap|clip-path";
const DECL = new RegExp(`(?:^|[^\\w-])['"]?(${PROPS})['"]?\\s*:\\s*([^;"}<>\\n]+)`, "gi");
const GENERIC = new Set(["serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "ui-sans-serif", "ui-serif", "ui-monospace", "-apple-system", "blinkmacsystemfont", "inherit", "initial", "unset", "emoji"]);
const ROLE_NAMES = ["title", "heading", "subheading", "lead", "body", "small", "caption", "label"];
const SCALE_NAMES = ["xs", "sm", "md", "lg", "xl", "xxl", "xxxl", "huge"];
const RADIUS_NAMES = ["small", "medium", "large", "xlarge"];

/** Every declaration in a piece of text, as [property, value], property in lower case. */
export function parseStyle(text) {
  const out = [];
  for (const m of String(text).matchAll(DECL)) {
    // Drop a quote or comma left from a generator's string, but keep a family's own quotes.
    let v = m[2].trim().replace(/,+$/, "");
    if ((v.match(/'/g) || []).length % 2) v = /^'/.test(v) ? v.slice(1) : v.replace(/'$/, "");
    v = v.replace(/^"|"$/g, "").replace(/,+$/, "").replace(/^'([^']*)'$/, "$1").trim();
    if (v) out.push([m[1].toLowerCase(), v]);
  }
  return out;
}

const hex2 = (n) => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, "0").toUpperCase();

/** Every colour in a value, as #RRGGBB (alpha dropped, short hex expanded, rgb() converted). */
export function colorsIn(value) {
  const out = [];
  for (const m of String(value).matchAll(/#([0-9a-f]{8}|[0-9a-f]{6}|[0-9a-f]{3})(?![0-9a-z])|rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/gi)) {
    if (m[1]) {
      let h = m[1].toUpperCase();
      if (h.length === 3) h = h.split("").map((c) => c + c).join("");
      out.push("#" + h.slice(0, 6));
    } else out.push("#" + hex2(+m[2]) + hex2(+m[3]) + hex2(+m[4]));
  }
  return out;
}

const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);

/** Relative luminance, 0 (black) to 1 (white). */
export function luminance(hex) {
  const [r, g, b] = rgb(hex).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** HSL saturation, 0 to 1. */
export function saturation(hex) {
  const c = rgb(hex), max = Math.max(...c), min = Math.min(...c), l = (max + min) / 2;
  if (max === min) return 0;
  return (max - min) / (1 - Math.abs(2 * l - 1));
}

/** "light", "dark" or "accent": a ground colour by its lightness, or a saturated one. */
export function classifyColor(hex) {
  const l = luminance(hex);
  if (saturation(hex) >= 0.4 && l > 0.045 && l < 0.85) return "accent";
  return l >= 0.4 ? "light" : "dark";
}

/** Numbers in px from a value: "12px 8px" gives [12, 8]; em, %, auto and 0 are left out. */
export function pxValues(value) {
  return [...String(value).matchAll(/(?<![\w.#-])(\d+(?:\.\d+)?)px\b/g)].map((m) => +m[1]).filter((n) => n > 0);
}

/** The first named family in a font-family value, and the rest as its fallback. */
export function familyOf(value) {
  const parts = String(value).split(",").map((s) => s.replace(/\\/g, "").trim().replace(/^['"]|['"]$/g, "").trim()).filter(Boolean);
  const name = parts.find((p) => !GENERIC.has(p.toLowerCase()) && !p.startsWith("var("));
  if (!name) return null;
  const rest = parts.filter((p) => p !== name).join(", ");
  return { name, fallback: rest || "system-ui, sans-serif" };
}

const weightOf = (v) => (/^bold/i.test(v) ? 700 : /^normal/i.test(v) ? 400 : /^\d{3}$/.test(v.trim()) ? +v.trim() : null);

/** A fresh tally. */
export function newTally() {
  return { bg: {}, bgLight: {}, bgDark: {}, ink: {}, inkLight: {}, inkDark: {}, border: {}, any: {}, families: {}, sizes: {}, weights: {}, radii: {}, space: {}, clipPaths: 0, combos: [], files: 0, pairs: 0 };
}

const bump = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };

/**
 * Adds one file's text to the tally. side is "light" or "dark" when the
 * file is one half of a Name / NameDark pair of screens, else null.
 */
export function collect(text, tally, side = null) {
  tally.files++;
  // Every six-digit colour anywhere, so a generator's palette literals count.
  for (const c of colorsIn(text.replace(/#[0-9a-f]{3}(?![0-9a-z])/gi, ""))) bump(tally.any, c);
  // A chunk is the text between double quotes or braces: one inline style,
  // one CSS rule, one string literal. A type role is read from one chunk.
  for (const chunk of text.split(/["{}]/)) {
    const decls = parseStyle(chunk);
    if (!decls.length) continue;
    const combo = {};
    for (const [p, v] of decls) {
      if (p === "background" || p === "background-color") {
        for (const c of colorsIn(v)) { bump(tally.bg, c); if (side === "light") bump(tally.bgLight, c); if (side === "dark") bump(tally.bgDark, c); }
      } else if (p === "color") {
        for (const c of colorsIn(v)) { bump(tally.ink, c); if (side === "light") bump(tally.inkLight, c); if (side === "dark") bump(tally.inkDark, c); }
      } else if (p === "border" || p === "border-color") {
        for (const c of colorsIn(v)) bump(tally.border, c);
      } else if (p === "font-family") {
        const f = familyOf(v);
        if (f) {
          combo.family = f.name;
          if (!tally.families[f.name]) tally.families[f.name] = { seen: 0, fallback: f.fallback, weights: {} };
          tally.families[f.name].seen++;
        }
      } else if (p === "font-size") {
        const [n] = pxValues(v);
        if (n) { bump(tally.sizes, n); combo.size = n; }
      } else if (p === "font-weight") {
        const w = weightOf(v);
        if (w) { bump(tally.weights, w); combo.weight = w; }
      } else if (p === "letter-spacing") {
        const m = v.match(/^(-?\d*\.?\d+)(em|px)?/);
        if (m) combo.letterSpacing = m[2] === "px" ? { px: +m[1] } : +m[1];
      } else if (p === "line-height") {
        const m = v.match(/^(\d*\.?\d+)(px)?/);
        if (m) combo.lineHeight = m[2] ? { px: +m[1] } : +m[1];
      } else if (p === "text-transform") {
        if (/uppercase/i.test(v)) combo.uppercase = true;
      } else if (p === "border-radius") {
        const [n] = pxValues(v);
        if (n) bump(tally.radii, n);
      } else if (p === "clip-path") {
        tally.clipPaths++;
      } else if (/^(padding|margin|gap|row-gap|column-gap)/.test(p)) {
        for (const n of pxValues(v)) bump(tally.space, n);
      }
    }
    if (combo.family && combo.weight) bump(tally.families[combo.family].weights, combo.weight);
    if (combo.size) tally.combos.push(combo);
  }
  return tally;
}

/** The entries of a count object, most seen first, ties by key. */
export const ranked = (o) => Object.entries(o).sort((a, b) => b[1] - a[1] || String(a[0]).localeCompare(String(b[0])));

/**
 * A scale from counted numbers: the `max` most seen values, smallest
 * first, named by `names` in order. Returns [{ key, value, seen }].
 */
export function buildScale(counts, max, names = SCALE_NAMES) {
  return ranked(counts).slice(0, Math.min(max, names.length)).map(([v, seen]) => ({ value: +v, seen }))
    .sort((a, b) => a.value - b.value).map((e, i) => ({ key: names[i], ...e }));
}

// The most common value of a field among combos; a combo without it counts
// as the default when `inherit` is false (no letter-spacing means 0).
const mostOf = (list, field, dflt, inherit = false) => {
  const c = {};
  for (const x of list) if (x[field] !== undefined || !inherit) bump(c, JSON.stringify(x[field] ?? dflt));
  const top = ranked(c)[0];
  return top ? JSON.parse(top[0]) : dflt;
};
const round = (n, d = 3) => Math.round(n * 10 ** d) / 10 ** d;

/** Colours of one kind ("light", "dark", "accent" or "any"), most seen first, leaving out `skip`. */
const pick = (counts, kind, skip = new Set()) => ranked(counts).filter(([c]) => !skip.has(c) && (kind === "any" || classifyColor(c) === kind));

/** The draft tokens object, in the shape design/tokens.json uses. */
export function draftTokens(t) {
  const paired = t.pairs > 0 && Object.keys(t.bgDark).length > 0;
  const ground = [], used = new Set();
  const add = (key, name, role, entry) => {
    if (!entry) return;
    ground.push({ key, name, hex: entry[0], role, seen: entry[1] });
    used.add(entry[0]);
  };
  // With pairs, the light half of each pair and the unpaired screens give the light ground.
  const lightBg = pick(t.bg, "light").filter(([c]) => !paired || (t.bg[c] || 0) > (t.bgDark[c] || 0));
  const darkInk = pick(t.ink, "dark").filter(([c]) => !paired || (t.ink[c] || 0) > (t.inkDark[c] || 0));
  add("page", "Page", "page background (the most used light background)", lightBg[0]);
  add("panel", "Panel", "panels, rows, cards (the next light background)", lightBg[1]);
  add("line", "Line", "borders and dividers (the most used border colour)", pick(t.border, "any", used)[0]);
  // Of the two most used dark text colours, the darker is the ink and the other the muted text.
  const inks = darkInk.filter(([c]) => !used.has(c)).slice(0, 2).sort((a, b) => luminance(a[0]) - luminance(b[0]));
  add("ink", "Ink", "main text (the darker of the two most used text colours)", inks[0]);
  add("muted", "Muted", "secondary text (the lighter of the two)", inks[1]);
  if (paired) {
    add("pageDark", "Page, dark", "page background on the dark screens", pick(t.bgDark, "dark", used)[0]);
    add("panelDark", "Panel, dark", "panels on the dark screens", pick(t.bgDark, "dark", used)[0]);
    add("inkDark", "Ink, dark", "main text on the dark screens", pick(t.inkDark, "light", used)[0]);
  } else {
    add("pageDark", "Page, dark", "the most used dark background; no dark screen pairs were found", pick(t.bg, "dark", used)[0]);
  }
  const colourCounts = { ...t.any };
  for (const src of [t.bg, t.ink, t.border]) for (const [c, n] of Object.entries(src)) if (!(c in colourCounts)) colourCounts[c] = n;
  const accents = pick(colourCounts, "accent", used).slice(0, 4).map(([hex, seen], i) => ({
    key: i ? `accent${i + 1}` : "accent", name: i ? `Accent ${i + 1}` : "Accent",
    role: i ? "a colour the mocks use often; name what it is for" : "the most used saturated colour",
    stops: [hex, hex, hex], seen,
  }));

  const famKeys = ["body", "display", "family3", "family4"];
  const families = ranked(Object.fromEntries(Object.entries(t.families).map(([k, v]) => [k, v.seen]))).slice(0, 4).map(([name, seen], i) => {
    const f = t.families[name];
    const weights = Object.keys(f.weights).map(Number).sort((a, b) => a - b);
    return { key: famKeys[i], name, fallback: f.fallback, weights: weights.length ? weights : [400], role: i ? "a family the mocks use; name its role" : "the most used family", seen };
  });
  const famKey = (name) => (families.find((f) => f.name === name) || families[0] || { key: "body" }).key;

  const roles = ranked(t.sizes).slice(0, ROLE_NAMES.length).map(([s, seen]) => ({ size: +s, seen })).sort((a, b) => b.size - a.size).map(({ size, seen }, i) => {
    const at = t.combos.filter((c) => c.size === size);
    const lh = mostOf(at, "lineHeight", 1.3, true), ls = mostOf(at, "letterSpacing", 0);
    return {
      key: ROLE_NAMES[i], family: famKey(mostOf(at, "family", families[0] && families[0].name, true)), size,
      weight: mostOf(at, "weight", 400, true),
      lineHeight: typeof lh === "object" ? round(lh.px / size, 2) : lh,
      letterSpacing: typeof ls === "object" ? round(ls.px / size) : ls,
      uppercase: mostOf(at, "uppercase", false), seen,
    };
  });

  const radiiScale = buildScale(Object.fromEntries(Object.entries(t.radii).filter(([v]) => +v < 999)), RADIUS_NAMES.length, RADIUS_NAMES);
  const roundSeen = Object.entries(t.radii).filter(([v]) => +v >= 999).reduce((s, [, n]) => s + n, 0);
  const radii = Object.fromEntries(radiiScale.map((e) => [e.key, e.value]).concat(roundSeen ? [["round", 999]] : []));
  const spaceScale = buildScale(t.space, SCALE_NAMES.length);

  const notes = [
    `A draft read from ${t.files} mock and generator files by scripts/design/seed-tokens.mjs. It is a person's starting point, never the finished look.`,
    "Name every key for what it is for, not its rank: accent2, subheading, md and the like are placeholders from how often a value was seen.",
    "Merge near-duplicates (two greys a shade apart, two sizes a pixel apart) and drop one-offs; each entry's seen count, and _seen for radii and spacing, says how often the mocks used it.",
    "Each accent repeats one colour as its three stops; set real stops if the look has a gradient.",
    paired ? `Light and dark were read from ${t.pairs} Name / NameDark screen pairs.` : "No Name / NameDark screen pairs were found, so light and dark were guessed by lightness alone.",
  ];
  if (t.clipPaths) notes.push(`The mocks shape ${t.clipPaths} corners or edges with clip-path; those are not radii and are not counted here.`);
  notes.push("Delete this _draft note, _seen and every seen field once the file is the look.");

  return {
    _draft: notes,
    _comment: "The one source of the project's look. Every platform's palette, type, spacing and icon tables are generated from this file by scripts/design/generate.mjs; a screen uses a token or a type role by name and never a literal colour, size or font.",
    version: 1,
    outputs: { ts: "design/generated/design.generated.ts", css: "design/generated/design.generated.css", kotlin: null, swift: null, fontUrlBase: "/fonts/" },
    ground,
    accents,
    gradients: [],
    type: { families, roles },
    radii,
    spacing: Object.fromEntries(spaceScale.map((e) => [e.key, e.value])),
    _seen: {
      radii: Object.fromEntries(radiiScale.map((e) => [e.key, e.seen]).concat(roundSeen ? [["round", roundSeen]] : [])),
      spacing: Object.fromEntries(spaceScale.map((e) => [e.key, e.seen])),
    },
    iconSizes: { small: 16, medium: 24, large: 48 },
    blocks: {},
    iconStroke: { linecap: "round", linejoin: "round", fill: "none" },
  };
}

/** Name / NameDark pairs among screen file names: a map from file name to "light" or "dark". */
export function pairSides(names) {
  const stem = (n) => n.replace(/(\.dc)?\.html?$/i, "");
  const set = new Set(names.map(stem)), sides = {};
  for (const n of names) {
    const s = stem(n);
    if (/Dark$/.test(s) && set.has(s.slice(0, -4))) sides[n] = "dark";
    else if (set.has(s + "Dark")) sides[n] = "light";
  }
  return sides;
}
