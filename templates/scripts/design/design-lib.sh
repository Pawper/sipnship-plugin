#!/bin/sh
# Pure helpers for the design checks. Nothing here reads a file or touches
# the network, so every function can be tested by feeding it strings.

# token_font_names TOKENS_JSON
# The font family names tokens.json declares, one per line.
token_font_names() {
  json_list "$1" families | grep -o '"name"[ \t]*:[ \t]*"[^"]*"' | sed 's/.*:[ \t]*"\([^"]*\)"/\1/'
}

# json_list JSON NAME: the text of the array "NAME": [ ... ], its own
# brackets balanced, so a list later in the file is never read into it.
json_list() {
  printf '%s' "$1" | tr -d '\r\n' | awk -v name="\"$2\"" '
    { i = index($0, name); if (!i) exit
      s = substr($0, i); j = index(s, "["); if (!j) exit
      depth = 0
      for (k = j; k <= length(s); k++) { c = substr(s, k, 1); if (c == "[") depth++; if (c == "]") { depth--; if (depth == 0) { print substr(s, j + 1, k - j - 1); exit } } } }'
}

# token_role_keys TOKENS_JSON
# The type role keys tokens.json declares, one per line.
token_role_keys() {
  json_list "$1" roles | grep -o '"key"[ \t]*:[ \t]*"[^"]*"' | sed 's/.*:[ \t]*"\([^"]*\)"/\1/'
}

# design_literals DIFF FONT_NAMES [ALLOW_RE]
# DIFF is a unified diff with zero context (git diff -U0) over UI files.
# Print each added line that carries a raw hex colour (#abc, #aabbcc,
# 0xFFaabbcc), a px, dp or sp number for type or spacing (0, 0.5 and 1
# are hairlines and pass), or a font name from FONT_NAMES (one per line),
# as "path:line: [the literals found] text", so a long line is never
# blamed on the wrong part (a "${pct}%" template beside a 40.dp). Lines
# matching ALLOW_RE (a regex, default: comment lines and @media) are
# skipped. Every drift one project fixed was a literal on one side; a
# screen says a token or a role by name.
design_literals() {
  dl_fonts=$(printf '%s\n' "$2" | sed '/^[[:space:]]*$/d' | sed 's/[][\.*^$]/\\&/g' | paste -sd'|' -)
  # awk -v strips one backslash, so the pattern carries two
  dl_allow='^[[:space:]]*(//|/\\*|\\*|#)|@media'
  [ -z "$3" ] || dl_allow="$dl_allow|$3"
  printf '%s\n' "$1" | tr -d '\r' | awk -v fonts="$dl_fonts" -v allow="$dl_allow" '
    /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); sub(/^\+\+\+ /, "", f); next }
    /^@@/ { n = $0; sub(/^@@ -[0-9,]+ \+/, "", n); sub(/[ ,].*/, "", n); line = n + 0; next }
    /^\+/ {
      t = substr($0, 2); cur = line; line++
      if (t ~ allow) next
      hit = ""
      s = t
      while (match(s, /#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])?([0-9a-fA-F][0-9a-fA-F])?([^0-9a-zA-Z_-]|$)/)) {
        m = substr(s, RSTART, RLENGTH); sub(/[^0-9a-fA-F#]$/, "", m); hit = hit ", " m
        s = substr(s, RSTART + RLENGTH)
      }
      s = t
      while (match(s, /0[xX][fF][fF][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/)) {
        hit = hit ", " substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      }
      s = t
      while (match(s, /[0-9]+(\.[0-9]+)?\.?(px|dp|sp)([^a-zA-Z0-9_]|$)/)) {
        m = substr(s, RSTART, RLENGTH); sub(/[^a-z0-9.]$/, "", m); num = m; sub(/\.?(px|dp|sp).*/, "", num)
        before = (RSTART > 1) ? substr(s, RSTART - 1, 1) : " "
        if (before !~ /[a-zA-Z0-9_.-]/ && num + 0 != 0 && num + 0 != 0.5 && num + 0 != 1) hit = hit ", " m
        s = substr(s, RSTART + RLENGTH)
      }
      if (fonts != "" && match(t, "[\"\x27](" fonts ")[\"\x27]")) hit = hit ", " substr(t, RSTART + 1, RLENGTH - 2)
      if (hit != "") printf "%s:%d: [%s] %s\n", f, cur, substr(hit, 3), t
    }'
}

# css_var_names TEXT
# The custom property names TEXT defines ("--name:"), one per line, sorted.
css_var_names() {
  printf '%s\n' "$1" | grep -o -- '--[A-Za-z0-9_-][A-Za-z0-9_-]*[[:space:]]*:' | sed 's/[[:space:]]*:$//' | sort -u
}

# css_var_gaps DIFF DEFINED_NAMES
# DIFF is a unified diff with zero context over UI files. Print each
# var(--name) an added line reads that DEFINED_NAMES (one per line: the
# generated design file's names and any the UI files set themselves) does
# not hold, as "path:line: --name", once per name and line. A name the
# generated file spells differently resolves to nothing and the rule
# quietly loses its colour or border.
css_var_gaps() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v defs="$(printf '%s\n' "$2" | paste -sd' ' -)" '
    BEGIN { n = split(defs, d, " "); for (i = 1; i <= n; i++) known[d[i]] = 1 }
    /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); sub(/^\+\+\+ /, "", f); next }
    /^@@/ { n = $0; sub(/^@@ -[0-9,]+ \+/, "", n); sub(/[ ,].*/, "", n); line = n + 0; next }
    /^\+/ {
      s = substr($0, 2); cur = line; line++; delete seen
      while (match(s, /var\([[:space:]]*--[A-Za-z0-9_-]+/)) {
        m = substr(s, RSTART, RLENGTH); sub(/^var\([[:space:]]*/, "", m)
        if (!(m in known) && !(m in seen)) { printf "%s:%d: %s\n", f, cur, m; seen[m] = 1 }
        s = substr(s, RSTART + RLENGTH)
      }
    }'
}

# copy_section COPY_ALLOW_TXT NAME
# The lines of one section of scripts/ci/copy-allow.txt ("user-facing
# calls:" or "allowed literals:"), comments and blank lines left out.
copy_section() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v want="$2:" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[a-z][a-z -]*:[[:space:]]*$/ { s = $0; sub(/[[:space:]]*$/, "", s); on = (s == want); next }
    on { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }'
}

# copy_literals DIFF CALLS [ALLOW_RE]
# DIFF is a unified diff with zero context over UI files. Print each added
# line that puts words on a screen as a literal, "path:line: [words] text":
# a JSX or template text child on one line (<p>Save</p>, in .tsx, .jsx,
# .vue, .svelte or .html files), a title, label, placeholder, alt or
# aria-label attribute or named argument with a quoted value, or a quoted
# literal passed straight to a function CALLS names (one per line: Text,
# toast). A literal counts only when it holds a letter and does not match
# ALLOW_RE (regexes joined by |, matched against the literal itself:
# identifiers, URLs, format strings). Comment lines never count. The rule
# reads one line at a time and only these shapes, so it misses words built
# up across lines or passed through a variable: it prefers missing a
# literal to blaming a line that holds none.
copy_literals() {
  cl_calls=$(printf '%s\n' "$2" | tr -d '\r' | sed '/^[[:space:]]*$/d' | sed 's/[][\.*^$]/\\&/g' | paste -sd'|' -)
  cl_allow=$(printf '%s' "${3:-}" | sed 's/\\/\\\\/g')
  printf '%s\n' "$1" | tr -d '\r' | awk -v calls="$cl_calls" -v allow="$cl_allow" '
    function words(s) { return s ~ /[A-Za-z]/ && (allow == "" || s !~ ("^(" allow ")$")) }
    function add(s) { if (words(s)) hit = hit ", " s }
    function boundary(str, at) { return at <= 1 || substr(str, at - 1, 1) !~ /[A-Za-z0-9_$.-]/ }
    # quoted(S): the literal at the start of S, quotes and all, or ""
    function quoted(s,   q, k) {
      q = substr(s, 1, 1); if (q != "\"" && q != "\047" && q != "`") return ""
      k = index(substr(s, 2), q); if (!k) return ""
      return substr(s, 1, k + 1)
    }
    function inner(lit,   v) { v = substr(lit, 2, length(lit) - 2); if (substr(lit, 1, 1) == "`" && index(v, "${")) return ""; return v }
    /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); sub(/^\+\+\+ /, "", f); jsx = (f ~ /\.(tsx|jsx|vue|svelte|html?)$/); next }
    /^@@/ { n = $0; sub(/^@@ -[0-9,]+ \+/, "", n); sub(/[ ,].*/, "", n); line = n + 0; next }
    /^\+/ {
      t = substr($0, 2); cur = line; line++
      if (t ~ /^[[:space:]]*(\/\/|\/\*|\*|#|<!--)/) next
      hit = ""
      if (jsx) {
        s = t; off = 0
        while (match(s, />[^<>{}]*</)) {
          c = substr(s, RSTART + 1, RLENGTH - 2); pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
          if (pre != "=" && pre != "-" && c !~ /[=&|();]/) add(c)
          s = substr(s, RSTART + RLENGTH - 1)
        }
      }
      s = t
      while (match(s, /(title|label|placeholder|alt|aria-label)[[:space:]]*[=:][[:space:]]*\{?[[:space:]]*["\047`]/)) {
        st = RSTART; ln = RLENGTH
        if (boundary(s, st)) { lit = quoted(substr(s, st + ln - 1)); if (lit != "") add(inner(lit)) }
        s = substr(s, st + ln)
      }
      if (calls != "") {
        s = t
        while (match(s, "(" calls ")[[:space:]]*\\([[:space:]]*[\"\047`]")) {
          st = RSTART; ln = RLENGTH
          if (boundary(s, st)) { lit = quoted(substr(s, st + ln - 1)); if (lit != "") add(inner(lit)) }
          s = substr(s, st + ln)
        }
      }
      if (hit != "") printf "%s:%d: [%s] %s\n", f, cur, substr(hit, 3), t
    }'
}

# design_escape TEXT
# Print the reason when a pull request body carries "Design: <reason>",
# nothing otherwise. A literal that must stay says why.
design_escape() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[[:space:]]*[Dd]esign:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' | head -n 1
}

# role_refs TEXT ROLE_KEYS
# The type roles TEXT references, one key per line. A role counts only in
# a reference form: a class "type-<key>" (type-rowClaim, type-row-claim),
# a member after a name (DesignType.RowClaim, AtText.rowClaim, ROLES.body),
# or a quoted index (ROLES["body"]). Import and package lines never count.
# A bare word did once: Compose's semantics.heading import and a string
# named station_week_heading made a phone screen "use" the heading role,
# and its web pair was reported as missing it.
role_refs() {
  rr_keys=$(printf '%s\n' "$2" | sed '/^[[:space:]]*$/d' | tr -d '\r' | paste -sd'|' -)
  [ -n "$rr_keys" ] || return 0
  printf '%s\n' "$1" | tr -d '\r' | awk -v keys="$rr_keys" '
    BEGIN {
      n = split(keys, k, "|")
      for (i = 1; i <= n; i++) {
        lo[i] = tolower(k[i])
        # rowClaim also reads as row-claim in a class name
        s = k[i]; gsub(/[A-Z]/, "-&", s); sub(/^-/, "", s); kb[i] = tolower(s)
      }
    }
    /^[[:space:]]*(import|package)[[:space:]]/ { next }
    {
      line = tolower($0)
      for (i = 1; i <= n; i++) {
        if (i in hit) continue
        if (match(line, "type-(" lo[i] "|" kb[i] ")([^a-z0-9_-]|$)")) { hit[i] = 1; continue }
        # A member counts only after a role holder: a name ending in type,
        # types, role, roles, text or typography (DesignType.Title,
        # ROLES.body, AtText.sentence). A request body read as
        # request.body, or foo().body, once made a screen "use" the body
        # role, and its pair was reported as missing it.
        if (match(line, "(type|types|role|roles|text|typography)\\." lo[i] "([^a-z0-9_]|$)")) {
          pre = substr(line, 1, RSTART); if (pre !~ /semantics$/) { hit[i] = 1; continue }
        }
        if (index(line, "[\"" lo[i] "\"]") || index(line, "[\047" lo[i] "\047]")) hit[i] = 1
      }
    }
    END { for (i = 1; i <= n; i++) if (i in hit) print k[i] }'
}

# role_mismatch NAME SIDE_A REFS_A SIDE_B REFS_B
# Print one line per role one side references and the other does not,
# "NAME: SIDE_A uses rowClaim, SIDE_B does not"; nothing when they agree.
role_mismatch() {
  rm_a=$(printf '%s\n' "$3" | sed '/^$/d' | sort -u); rm_b=$(printf '%s\n' "$5" | sed '/^$/d' | sort -u)
  printf '%s\n' "$rm_a" | while IFS= read -r k; do [ -n "$k" ] || continue; printf '%s\n' "$rm_b" | grep -qx "$k" || printf '%s: %s uses %s, %s does not\n' "$1" "$2" "$k" "$4"; done
  printf '%s\n' "$rm_b" | while IFS= read -r k; do [ -n "$k" ] || continue; printf '%s\n' "$rm_a" | grep -qx "$k" || printf '%s: %s uses %s, %s does not\n' "$1" "$4" "$k" "$2"; done
}

# new_lines BEFORE AFTER
# The lines of AFTER that are not in BEFORE, in AFTER's order: the role
# mismatches a change adds. A pair that already differed fails no pull
# request that leaves the gap as it was; one that widens it fails.
new_lines() {
  printf '%s\n' "$2" | while IFS= read -r nl_l; do
    [ -n "$nl_l" ] || continue
    printf '%s\n' "$1" | grep -qxF -- "$nl_l" || printf '%s\n' "$nl_l"
  done
}

# parity_pairs PARITY_TXT
# The screen pairs of scripts/ci/parity.txt, "NAME<TAB>PATH_A<TAB>PATH_B".
parity_pairs() {
  printf '%s\n' "$1" | tr -d '\r' | awk '!/^[[:space:]]*(#|$)/ && NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }'
}

# day_number YYYY-MM-DD: days since 1970-01-01, in awk, for dates kept as
# the owner's local day (no clock, no zone).
day_number() {
  printf '%s\n' "$1" | awk -F- '{
    y = $1 + 0; m = $2 + 0; d = $3 + 0
    if (m <= 2) { y--; m += 12 }
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m - 3) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    print era * 146097 + doe - 719468 }'
}

# stale_screens PAIRS RECORDS TODAY [DAYS]
# PAIRS is parity_pairs output; RECORDS the lines of design/screens.txt
# ("NAME DATE BY"); TODAY the owner's day. Print each pair never compared,
# or compared more than DAYS (default 14) ago, as "NAME: never" or
# "NAME: N days", worst first. KIND "mock" reads the mock-vs-build lines
# ("NAME DATE BY mock") instead of the cross-platform ones.
stale_screens() {
  ss_today=$(day_number "$3")
  printf '%s\n' "$1" | awk -F'\t' 'NF >= 1 && $1 != "" { print $1 }' | while IFS= read -r ss_n; do
    ss_date=$(printf '%s\n' "$2" | tr -d '\r' | awk -v n="$ss_n" -v k="${5:-}" '!/^[[:space:]]*#/ && $1 == n && ((k == "mock") == ($4 == "mock")) { d = $2 } END { print d }')
    if [ -z "$ss_date" ]; then printf '99999\t%s: never\n' "$ss_n"
    else
      ss_age=$(( ss_today - $(day_number "$ss_date") ))
      if [ "$ss_age" -gt "${4:-14}" ]; then printf '%s\t%s: %s days\n' "$ss_age" "$ss_n" "$ss_age"; fi
    fi
  done | sort -t"$(printf '\t')" -k1,1nr | cut -f2
}

# parity_unpaired PATHS PARITY_TXT
# PATHS are changed files, one per line. Print each that sits in a folder
# some pair's path sits in, has the same extension as that pair's path,
# and is itself in no pair, unless a line "unpaired PATH" in PARITY_TXT
# declares it one-sided. Pairs drift as a project grows: four Settings
# blocks added in a week were never paired, and every Android Settings
# edit then failed parity until someone noticed.
parity_unpaired() {
  pu_pairs=$(parity_pairs "$2")
  pu_known=$(printf '%s\n' "$pu_pairs" | awk -F'\t' '{ print $2; print $3 }')
  pu_exempt=$(printf '%s\n' "$2" | tr -d '\r' | awk '$1 == "unpaired" && NF >= 2 { print $2 }')
  pu_dirs=$(printf '%s\n' "$pu_known" | awk '{ d = $0; e = $0; sub(/\/[^\/]*$/, "", d); sub(/.*\./, "", e); print d "\t" e }' | sort -u)
  printf '%s\n' "$1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | while IFS= read -r pu_p; do
    printf '%s\n' "$pu_known" | grep -qxF "$pu_p" && continue
    printf '%s\n' "$pu_exempt" | grep -qxF "$pu_p" && continue
    pu_d=${pu_p%/*}; pu_e=${pu_p##*.}
    [ "$pu_d" != "$pu_p" ] || continue
    if printf '%s\n' "$pu_dirs" | grep -qxF "$pu_d	$pu_e"; then printf '%s\n' "$pu_p"; fi
  done
}

# parity_groups PAIRS
# PAIRS is parity_pairs output. One line per comparison to make:
# "FILE<TAB>PARTNER PARTNER ..." for a file that several pairs name (a
# native screen paired with each web block it holds): its roles are
# compared with the union of its partners', so a block is never measured
# against the whole screen alone. A pair whose files are in no other pair
# is one line "A<TAB>B".
parity_groups() {
  printf '%s\n' "$1" | awk -F'\t' '
    NF >= 3 { a[NR] = $2; b[NR] = $3; n[$2]++; n[$3]++; p[$2] = p[$2] " " $3; p[$3] = p[$3] " " $2 }
    END {
      for (i = 1; i <= NR; i++) {
        if (a[i] == "") continue
        if (n[a[i]] >= 2) { if (!(a[i] in done)) { done[a[i]] = 1; sub(/^ /, "", p[a[i]]); print a[i] "\t" p[a[i]] } }
        if (n[b[i]] >= 2) { if (!(b[i] in done)) { done[b[i]] = 1; sub(/^ /, "", p[b[i]]); print b[i] "\t" p[b[i]] } }
        if (n[a[i]] < 2 && n[b[i]] < 2) print a[i] "\t" b[i]
      }
    }'
}

# side_touched SIDE CHANGED
# "yes" when CHANGED (one path per line) changes the pair side SIDE: the
# file itself, or, for a side that ends in "/" (a folder, as parity.txt
# allows), any file under it. A folder side once never counted as touched,
# because only whole lines were matched.
side_touched() {
  printf '%s\n' "$2" | tr -d '\r' | awk -v s="$1" '
    $0 == "" { next }
    s ~ /\/$/ { if (index($0, s) == 1) { hit = 1; exit } next }
    $0 == s { hit = 1; exit }
    END { print (hit ? "yes" : "no") }'
}

# side_files SIDE LISTING
# The files a pair side stands for: SIDE itself, or, for a folder side
# (ending in "/"), every path of LISTING (one per line, as git ls-tree -r
# --name-only prints it) under the folder, leaving out node_modules and
# build output. A folder read as one file once gave its file names, and
# every role on the other platform was reported missing.
side_files() {
  case "$1" in
    */) printf '%s\n' "$2" | tr -d '\r' | awk -v s="$1" 'index($0, s) == 1 && $0 !~ /(^|\/)(node_modules|build)\// { print }' ;;
    *) printf '%s\n' "$1" ;;
  esac
}
