#!/bin/sh
# End-to-end trial: copy the templates into a fresh repository and run every
# check the way a new project would. Needs git, node and curl. It creates a
# temporary folder and prints its path at the end; nothing is deleted.
# Run from the repository root: sh tests/trial.sh
set -e
plugin=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)/trial
mkdir -p "$work" && cd "$work"
git init -q && git config user.email trial@example.com && git config user.name Trial
step() { printf '\n== %s\n' "$1"; }
expect_fail() { if "$@" >/dev/null 2>&1; then echo "UNEXPECTED: passed"; exit 1; else echo "failed as it should"; fi; }

step "copy the templates"
cp -R "$plugin/templates/." .
sed -i 's/PROJECT_NAME/Trial/g' CLAUDE.md AGENTS.md console/services.json
mkdir -p src && echo "export const a = 1;" > src/a.ts
git add -A && git commit -q -m "bootstrap"

step "status page: build, check, then go stale"
sh status/build.sh && sh status/check.sh
printf 'name: Search\nstate: not started\n' > status/stubs/search.md
expect_fail sh status/check.sh
sh status/build.sh >/dev/null && git add -A && git commit -q -m "add search stub"

step "classifier on a mixed change"
printf 'src/a.ts\ndocs/x.md\nstatus/stubs/search.md\nweird.bin\n' | sh scripts/ci/classify.sh

step "spec check: src without a spec fails, with one passes"
printf 'src/a.ts\n' > paths.txt
expect_fail sh -c 'sh scripts/ci/spec-check.sh < paths.txt'
printf 'src/a.ts\nspecs/search/spec.md\n' | sh scripts/ci/spec-check.sh

step "setup check"
printf 'migrations/0001.sql\n' > paths.txt
expect_fail sh -c 'sh scripts/ci/setup-check.sh < paths.txt'
printf 'migrations/0001.sql\nSETUP.md\n' | sh scripts/ci/setup-check.sh

step "line endings"
sh scripts/ci/line-endings.sh
printf 'a\r\nb\r\n' > crlf.txt && git add crlf.txt
expect_fail sh scripts/ci/line-endings.sh
git rm -q --cached crlf.txt && mv crlf.txt crlf.txt.aside

step "console: check, then serve and read the page"
node "$plugin/console/cli.js" console --check
printf 'DATABASE_URL=postgres://x\nDONE_BACKUP=1\n' > .env
node "$plugin/console/cli.js" console --port 7790 >/dev/null 2>&1 &
pid=$!
sleep 1
curl -s http://127.0.0.1:7790/ > page.html
kill $pid
cards=$(grep -c '<section class="card"' page.html)
echo "cards: $cards"
grep -q 'Database</h3><span class="state ready"' page.html && echo "database card is ready from .env"
grep -q 'class="done">Schedule the backup' page.html && echo "backup item cleared from its flag"
if grep -q 'DATABASE_URL' page.html; then echo "UNEXPECTED: a variable name is on the page"; exit 1; fi
echo "no variable names on the page"

step "move aside instead of delete"
git mv NOTICE.md aside-NOTICE.md && git commit -q -m "move aside" && echo "moved"

printf '\nTrial passed. The repository is at %s\n' "$work"
