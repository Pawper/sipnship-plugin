#!/bin/sh
# Fail when source code hands process.env to anything whole. Next.js and
# similar bundlers inline a public variable only where it is named
# literally, as process.env.NEXT_PUBLIC_X; passed whole, process.env is an
# empty object in the browser, and every client screen that reads through
# it breaks while the tests and the type-check pass. One project shipped a
# sign-in that froze this way, from readPublicEnv(process.env) in a module
# the client screens imported; that module was not itself "use client", so
# the check looks at every source file, not only those.
#
# A file that only ever runs on the server says so and is skipped: it
# imports "server-only", is a route handler or middleware, ends in
# .server.ts, or carries the comment "env-check: server".
# Usage: sh scripts/ci/client-env-check.sh [DIR...]   (default: src app)
dirs=${*:-src app}
bad=""
for d in $dirs; do
  [ -d "$d" ] || continue
  files=$(grep -rlE 'process\.env([^.[A-Za-z0-9_]|$)' "$d" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.mjs' 2>/dev/null)
  for f in $files; do
    case "$f" in
      *.test.*|*.spec.*|*/route.ts|*/route.js|*middleware.ts|*middleware.js|*.server.ts|*.server.js) continue ;;
    esac
    grep -qE "import ['\"]server-only['\"]|env-check: server" "$f" 2>/dev/null && continue
    hits=$(grep -nE 'process\.env([^.[A-Za-z0-9_]|$)' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*(//|\*)')
    [ -n "$hits" ] && bad="$bad$(printf '%s\n' "$hits" | sed "s#^#$f:#")
"
  done
done
if [ -n "$bad" ]; then
  echo "Source code passes process.env whole. In the browser it is empty; name each public variable literally (process.env.NEXT_PUBLIC_X) where it is read, or mark a server-only file with import \"server-only\":" >&2
  printf '%s' "$bad" >&2
  exit 1
fi
echo "No source file passes process.env whole."
