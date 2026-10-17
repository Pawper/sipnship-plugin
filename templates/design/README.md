# Design: one source, generated into every platform

`tokens.json` and `icons.json` are the source of the project's look. Each platform's palette, type, spacing and icon tables are generated from them, never written by hand, so a web screen and an Android (or iOS) screen read the same values and a change is one line here.

| File | Holds |
|---|---|
| `tokens.json` | Ground colours, accents with three gradient stops, gradients, type families and **type roles**, radii, spacing, icon sizes, per-feature blocks |
| `icons.json` | Every icon by a stable key: view box size, stroke width, parts as SVG paths |
| `fonts/` | The bundled font files named in `tokens.json`, each with its licence text |
| `screens.txt` | When each screen pair was last compared across platforms, by eye (see below) |

## Generate

```bash
node scripts/design/generate.mjs
```

writes the files named under `outputs` in `tokens.json`: a TypeScript module, a CSS file (custom properties, `@font-face` rules and one class per type role, `.type-<role>`), a Kotlin object (colours as ARGB, sizes in sp and dp, `DesignType.<Role>` as a `DesignRole`, icon paths for `PathParser`) and a Swift enum. Set an output to `null` to leave a platform out. `--check` writes nothing and fails when any generated file is out of date; CI runs it. Change a value here, regenerate, and commit both in the same pull request.

The generator is the plugin's file and the sync keeps it current. A project's own sections (a wordmark, an ambient light, anything its tokens carry beyond the standard keys) go in `scripts/design/generate.local.mjs`, which exports `extra({ tokens, icons, helpers })` and returns `{ ts, css, kotlin, swift }` strings the generator appends to each file.

## Rules a screen follows

- **A screen uses a token or a role, never a literal.** No raw hex colour, no px, dp or sp number for type or spacing, no font name outside the generated module. CI fails a pull request that adds one to a UI file (`scripts/ci/design-check.sh`); the generated files and `design/` itself are allowed. A literal that must stay says why in the pull request body: `Design: <reason>`.
- **Type roles are the unit, not sizes.** "rowClaim: sans 15/1.3 600" is one line here that both platforms follow; a screen says the role's name (`class="type-rowClaim"`, `DesignType.RowClaim`). A decision such as "card text reads in the body sans" is one line in `tokens.json`, not a six-file pull request.
- **A colour chosen by data is a core rule; a colour chosen by design is a token.** A mood's colour, a state's tone, anything picked by what the data says belongs in the shared core with fixtures, and the tokens supply the palette it picks from. A colour picked once by the designer is a token.

## Parity across platforms

When `scripts/ci/parity.txt` lists screen pairs (`NAME PATH_A PATH_B`), the design check also compares, per pair a pull request touches, the token and role names each side references, and fails when one side uses a role the other does not. That catches the drift a file-pair check cannot: both sides changed, and one stopped matching. A file that several pairs name (a native screen paired with each web block it holds) is compared with the union of its partners' roles, so a block is never measured against the whole screen alone. The check reads the role names a screen says directly (`type-rowClaim`, `DesignType.RowClaim`); a web screen that reaches a role through its own class in a stylesheet does not count as naming it, which is one more reason a screen says the role.

Pairs drift as a project grows: a new screen file lands in a folder whose others are paired, and nobody lists it until the other platform's edits start failing. The check also fails a pull request that adds or changes a file in a folder some pair lists, with the same extension, that is in no pair itself; a line `unpaired PATH` in `parity.txt` declares a file one-sided on purpose.

A file-pair check never catches a screen that simply looks different. `screens.txt` records, per pair, the day a person last compared the two platforms by eye; the session brief names the pairs never compared or not compared in 14 days. After comparing, record it:

```bash
sh scripts/design/screens.sh compare today evening
```

The check says what it is doing, one line per step, and gives up after 90 seconds naming the step it was in (`DESIGN_CHECK_SECONDS` raises that). A run that prints nothing for minutes is a slow step with a name, never a hang to background and forget.
