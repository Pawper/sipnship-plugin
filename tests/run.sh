#!/bin/sh
# Tests for the pure part of every script in this repository.
# Run from the repository root with: sh tests/run.sh
# Needs only sh and awk, like the scripts themselves.

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/hooks/scripts/lib.sh"
. "$root/templates/status/lib.sh"
. "$root/templates/scripts/ci/lib.sh"

pass=0
fail=0

# eq NAME EXPECTED ACTUAL
eq() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
  fi
}

printf '\n# json_field\n'
eq "reads a string field" "ls -la" "$(json_field '{"tool_input":{"command":"ls -la"}}' command)"
eq "undoes escapes" 'echo "hi" && cat a\b' "$(json_field '{"command":"echo \"hi\" && cat a\\b"}' command)"
eq "turns \\n into a newline" "a
b" "$(json_field '{"command":"a\nb"}' command)"
eq "missing key prints nothing" "" "$(json_field '{"x":"y"}' command)"
eq "skips spaces around the colon" "p" "$(json_field '{ "file_path" : "p" }' file_path)"

printf '\n# split_commands\n'
eq "splits on && ; | and ||" "a
b
c
d" "$(split_commands 'a && b; c | d')"
eq "strips env assignments and sudo" "rm x" "$(split_commands 'FOO=1 sudo rm x')"
eq "sees inside a subshell" "echo
rm x" "$(split_commands 'echo $(rm x)')"
eq "joins a backslash continuation" "gh issue create --title x --label state:ready" "$(split_commands 'gh issue create \
  --title x \
  --label state:ready')"
eq "skips a heredoc body" "cat > f.yml <<EOF
echo done" "$(split_commands 'cat > f.yml <<EOF
run: gh issue create --title x
rm -rf nothing
EOF
echo done')"
eq "skips a quoted heredoc body" "cat <<'EOF' > f
ls" "$(split_commands "cat <<'EOF' > f
rm -rf /
EOF
ls")"
eq "a label on a continued line counts" "" "$(state_label_reason 'gh issue create \
  --title "main is red" \
  --label "ci-red,state:ready" \
  --body "x"')"
eq "a create inside a heredoc is not a command" "" "$(state_label_reason 'cat > .github/workflows/ci.yml <<EOF
        run: gh issue create --title x
EOF')"
eq "a heredoc file first, then the labeled create" "" "$(state_label_reason "cat > b.md <<'EOF'
Body text here.
EOF
gh issue create --title t --label \"state: in progress\" --body-file b.md")"
eq "the label after --body-file" "" "$(state_label_reason 'gh issue create --title t --body-file b.md --label "state: in progress"')"
eq "a body from a heredoc inside a substitution, label after it" "" "$(state_label_reason "gh issue create --title t --body \"\$(cat <<'EOF'
Body text here.
EOF
)\" --label \"state: ready\"")"
eq "the same shape with no label is still refused" "gh issue create" "$(state_label_reason "gh issue create --title t --body \"\$(cat <<'EOF'
Body text here.
EOF
)\"")"
eq "a heredoc body that mentions gh issue create" "" "$(state_label_reason "cat > b.md <<'EOF'
Run gh issue create without a label to see the hook refuse it.
EOF
gh issue create --title t --label state:ready --body-file b.md")"
eq "an rm inside a heredoc is not a command" "" "$(delete_reason 'cat > script.sh <<EOF
rm -rf build
EOF')"
eq "a command after the heredoc still counts" "rm" "$(delete_reason 'cat > s.sh <<EOF
echo hi
EOF
rm -rf build')"

printf '\n# delete_reason\n'
eq "rm" "rm" "$(delete_reason 'rm -rf build')"
eq "rm after cd" "rm" "$(delete_reason 'cd x && rm -r y')"
eq "rm by full path" "rm" "$(delete_reason '/bin/rm x')"
eq "rmdir" "rmdir" "$(delete_reason 'rmdir empty')"
eq "del" "del" "$(delete_reason 'del /q file.txt')"
eq "Remove-Item" "Remove-Item" "$(delete_reason 'Remove-Item -Recurse out')"
eq "Remove-Item inside powershell" "remove-item" "$(delete_reason 'powershell -Command "Remove-Item out"')"
eq "del inside cmd /c" "del" "$(delete_reason 'cmd /c del x.txt')"
eq "git clean" "git clean" "$(delete_reason 'git clean -fdx')"
eq "git status is fine" "" "$(delete_reason 'git status && ls')"
eq "a word containing rm is fine" "" "$(delete_reason 'npm run format')"
eq "git rm is not a delete of history" "" "$(delete_reason 'git rm --cached x')"
eq "removing in a string is fine" "" "$(delete_reason 'echo "do not rm this"')"

printf '\n# force_push_reason\n'
eq "--force" "--force" "$(force_push_reason 'git push --force origin main')"
eq "--force-with-lease" "--force-with-lease=main" "$(force_push_reason 'git push --force-with-lease=main origin main')"
eq "-f" "-f" "$(force_push_reason 'git push -f')"
eq "combined short flags" "-uf" "$(force_push_reason 'git push -uf origin x')"
eq "plus refspec" "+main" "$(force_push_reason 'git push origin +main')"
eq "quoted plus refspec" "+main" "$(force_push_reason "git push origin '+main'")"
eq "after git -C" "--force" "$(force_push_reason 'git -C /repo push --force')"
eq "plain push is fine" "" "$(force_push_reason 'git push -u origin feature')"
eq "a commit named force is fine" "" "$(force_push_reason 'git commit -m "force"')"
eq "push in a later command" "-f" "$(force_push_reason 'git fetch && git push -f')"

printf '\n# full_sweep_reason\n'
eq "bare pytest" "pytest" "$(full_sweep_reason 'pytest')"
eq "pytest with options only" "pytest" "$(full_sweep_reason 'pytest -q --maxfail=1')"
eq "pytest with a file is fine" "" "$(full_sweep_reason 'pytest tests/test_a.py')"
eq "listing the runner binary is not a sweep" "" "$(full_sweep_reason 'ls node_modules/.bin/vitest')"
eq "a quoted test path is targeted" "" "$(full_sweep_reason 'npx vitest run "tests/unit/a.test.ts"')"
eq "npm t with a file is targeted" "" "$(full_sweep_reason 'npm t -- a.test.ts')"
eq "the runner named in a string is not a run" "" "$(full_sweep_reason 'gh issue create --title "vitest sweeps" --body "npm test is a gate" --label state:ready')"
eq "pytest with -k is fine" "" "$(full_sweep_reason 'pytest -k login')"
eq "npm test" "npm test" "$(full_sweep_reason 'npm test')"
eq "npm run test" "npm test" "$(full_sweep_reason 'npm run test -- --coverage')"
eq "npm test with a file is fine" "" "$(full_sweep_reason 'npm test -- src/a.test.ts')"
eq "yarn test" "yarn test" "$(full_sweep_reason 'yarn test')"
eq "pnpm test" "pnpm test" "$(full_sweep_reason 'pnpm test')"
eq "npx jest" "jest" "$(full_sweep_reason 'npx jest')"
eq "npx vitest run with a file is fine" "" "$(full_sweep_reason 'npx vitest run src/a.test.ts')"
eq "vitest run alone" "vitest" "$(full_sweep_reason 'vitest run')"
eq "go test ./..." "go test" "$(full_sweep_reason 'go test ./...')"
eq "go test one package is fine" "" "$(full_sweep_reason 'go test ./pkg/auth')"
eq "cargo test" "cargo test" "$(full_sweep_reason 'cargo test')"
eq "cargo test with a filter is fine" "" "$(full_sweep_reason 'cargo test parse_date')"
eq "dotnet test" "dotnet test" "$(full_sweep_reason 'dotnet test')"
eq "dotnet test with --filter is fine" "" "$(full_sweep_reason 'dotnet test --filter Name~Login')"
eq "python -m pytest" "pytest" "$(full_sweep_reason 'python -m pytest')"
eq "uv run pytest" "pytest" "$(full_sweep_reason 'uv run pytest')"
eq "a sweep after cd" "pytest" "$(full_sweep_reason 'cd app && pytest')"
for ext in ts tsx js jsx mjs cjs; do
  eq "one named .test.$ext file is not a sweep" "" "$(full_sweep_reason "npx vitest run src/Foo.test.$ext")"
  eq "one named .spec.$ext file is not a sweep" "" "$(full_sweep_reason "npx vitest run src/Foo.spec.$ext")"
done
eq "one .tsx file with a project flag" "" "$(full_sweep_reason 'npx vitest run src/Foo.test.tsx --project dom')"
eq "one .tsx file with a config flag first" "" "$(full_sweep_reason 'npx vitest run --config vitest.dom.config.ts src/Foo.test.tsx')"
eq "one .tsx file with Windows separators" "" "$(full_sweep_reason 'npx vitest run src\Foo.test.tsx')"
eq "one .tsx file piped to tail" "" "$(full_sweep_reason 'npx vitest run src/Foo.test.tsx 2>&1 | tail -20')"
eq "npm run build is fine" "" "$(full_sweep_reason 'npm run build')"
eq "ls is fine" "" "$(full_sweep_reason 'ls tests')"

printf '\n# generated_page_reason\n'
pages="# comment
STATUS.md
docs/generated/*"
eq "matches by file name" "STATUS.md" "$(generated_page_reason /proj/STATUS.md /proj "$pages")"
eq "matches a Windows path" "STATUS.md" "$(generated_page_reason 'C:\proj\STATUS.md' 'C:\proj' "$pages")"
eq "matches a path pattern" "docs/generated/api.md" "$(generated_page_reason /proj/docs/generated/api.md /proj "$pages")"
eq "matches a path pattern when the root is unknown" "/other/docs/generated/api.md" "$(generated_page_reason /other/docs/generated/api.md /proj "$pages")"
eq "a stub is fine" "" "$(generated_page_reason /proj/status/stubs/x.md /proj "$pages")"
eq "an unrelated file is fine" "" "$(generated_page_reason /proj/src/a.ts /proj "$pages")"
eq "a comment line never matches" "" "$(generated_page_reason '/proj/# comment' /proj "$pages")"

printf '\n# state_label_reason\n'
eq "no label" "gh issue create" "$(state_label_reason 'gh issue create --title x --body y')"
eq "a label without a state" "gh issue create" "$(state_label_reason 'gh issue create -t x -l bug')"
eq "--label state:" "" "$(state_label_reason 'gh issue create -t x --label state:ready')"
eq "-l with a list" "" "$(state_label_reason 'gh issue create -t x -l bug,state:parked')"
eq "--label= form" "" "$(state_label_reason 'gh issue create --label=state:dated -t x')"
eq "quoted label" "" "$(state_label_reason "gh issue create -l 'state:waiting-on-owner' -t x")"
eq "--web opens the form, which requires it" "" "$(state_label_reason 'gh issue create --web')"
eq "a quoted list with spaces" "" "$(state_label_reason 'gh issue create --title x --label "ci-red, state: ready" --body y')"
eq "a quoted list with spaces on a continued line" "" "$(state_label_reason 'gh issue create \
  --title "main is red" \
  --label "ci-red, state: ready" \
  --body y')"
eq "a quoted label with a space but no state" "gh issue create" "$(state_label_reason 'gh issue create -l "needs triage" -t x')"
eq "gh issue list is fine" "" "$(state_label_reason 'gh issue list')"
eq "create in a later command" "gh issue create" "$(state_label_reason 'git push && gh issue create -t x')"

printf '
# project_flag_reason
'
eq "no --project" "gh issue create" "$(project_flag_reason 'gh issue create -t x -b y')"
eq "--project" "" "$(project_flag_reason 'gh issue create -t x --project "Retro Jam"')"
eq "-p" "" "$(project_flag_reason 'gh issue create -t x -p Board')"
eq "a state label alone is not enough here" "gh issue create" "$(project_flag_reason 'gh issue create -t x -l state:ready')"
eq "--web" "" "$(project_flag_reason 'gh issue create --web')"

printf '\n# batch_merge_reason\n'
eq "three PRs with no flag" "3" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh 41 42 45')"
eq "three PRs with --batch" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --batch 41 42 45')"
eq "three PRs with --serial" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --serial 41 42 45')"
eq "two PRs with no flag" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh 41 42')"
eq "one PR as before" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh 41 main')"
eq "a chained serial run after cd" "4" "$(batch_merge_reason 'cd app && sh ./scripts/ci/merge-queue.sh 1 2 3 4')"
eq "another script with numbers is fine" "" "$(batch_merge_reason 'sh scripts/other.sh 1 2 3')"

printf '\n# batch helpers\n'
. "$root/templates/scripts/ci/batch-lib.sh"
eq "order kept, repeats dropped, words ignored" "41
42
45" "$(batch_order 41 42 41 x 45 | tr '\n' ' ' | sed 's/ $//' | tr ' ' '\n')"
eq "test files from a diff" "tests/unit/a.test.ts
src/b.spec.tsx" "$(tests_for_diff 'src/a.ts
tests/unit/a.test.ts
src/b.spec.tsx
docs/x.md
e2e/login.spec.ts
tests/e2e/flow.test.ts')"
eq "no test files, nothing" "" "$(tests_for_diff 'src/a.ts
README.md')"
eq "branch name for the day" "batch-2026-10-03" "$(batch_branch_name 2026-10-03)"
eq "second batch of the day" "batch-2026-10-03-2" "$(batch_branch_name 2026-10-03 2)"
eq "batch PR body" "- #41 Add retries. Closes #41
- #45 Fix the parser. Closes #45" "$(batch_pr_body "$(printf '41\tAdd retries\n45\tFix the parser\n')" | tail -n 2)"
eq "one line per PR" "#13 dropped: conflicts with the batch so far" "$(batch_line 13 dropped 'conflicts with the batch so far')"
eq "one line without a reason" "#12 merged into the batch" "$(batch_line 12 'merged into the batch')"

printf '\n# session brief\n'
. "$root/hooks/scripts/session-brief-lib.sh"
fx="$root/tests/fixtures"
eq "json_number reads a number" "40" "$(json_number '{"maxLines": 40, "x": "y"}' maxLines)"
eq "json_number missing key" "" "$(json_number '{"x": 1}' maxLines)"
eq "the brief says when the permission file is missing" "Waits on the owner: the agent is not allowed to grant itself permissions, so .claude/settings.json is yours to add. Run node console/cli.js permissions in a terminal." "$(permissions_line "$fx/permissions/none.json")"
eq "the brief says nothing when the permission file is there" "" "$(permissions_line "$fx/permissions/settings-present.json")"
eq "a refused deploy names the cause, the wizard and the command" "The agent is not allowed to start a deploy here, so nothing was deployed. Add the permission file with node console/cli.js permissions, or run this one command yourself: gh workflow run deploy.yml --ref main" "$(deploy_refused_message main)"
eq "pr line, green" "#41 Add retries to the client (mergeable, CI green)" "$(pr_line "$(sed -n 1p "$fx/pr-list.tsv")")"
eq "pr line, conflicts and a failure" "#42 Fix the date parser (has conflicts, CI 1 failed)" "$(pr_line "$(sed -n 2p "$fx/pr-list.tsv")")"
eq "pr line, pending" "#45 Rename the status page (mergeability unknown, CI 2 pending)" "$(pr_line "$(sed -n 3p "$fx/pr-list.tsv")")"
eq "pr line, no CI" "#47 Docs only (mergeable, no CI yet)" "$(pr_line "$(sed -n 4p "$fx/pr-list.tsv")")"
eq "today names the zone" "Today: Friday 2026-10-09, 22:00 PDT. Dates in this repository are America/Los_Angeles days; gh and runner timestamps are UTC, convert before writing one." "$(today_line 'Friday 2026-10-09, 22:00 PDT' America/Los_Angeles)"
eq "today without a zone says local" "Today: Friday 2026-10-09, 22:00 PDT. Dates in this repository are the owner's local day; gh and runner timestamps are UTC, convert before writing one." "$(today_line 'Friday 2026-10-09, 22:00 PDT' TIMEZONE)"
eq "a Windows path becomes Claude Code's project slug" "C--Users-me-Documents-GitHub-repo" "$(project_slug 'C:\Users\me\Documents\GitHub\repo')"
eq "a Unix path becomes the slug too" "-Users-me-repo" "$(project_slug '/Users/me/repo')"
eq "log written an hour ago is recent" "yes" "$(log_is_recent 1000000 1003600)"
eq "log written three hours ago is not" "no" "$(log_is_recent 1000000 1010800)"
eq "log with a bad time is not" "no" "$(log_is_recent '' 1000000)"
eq "gh pr view is GraphQL" "gh pr view" "$(gh_graphql_reason 'gh pr view 12 --json state')"
eq "gh issue create too" "gh issue create" "$(gh_graphql_reason 'cd x && gh issue create --title t')"
eq "gh api graphql too" "gh api graphql" "$(gh_graphql_reason 'gh api graphql -f query=q')"
eq "gh api on a REST path is not" "" "$(gh_graphql_reason 'gh api repos/{owner}/{repo}/pulls/12 --jq .state')"
eq "gh run and git are not" "" "$(gh_graphql_reason 'gh run list; git push; gh auth status')"
eq "a cached budget younger than a minute is read" "4120	5000	1760000000	3469	5000	1760000000" "$(budget_cached '1759999950	4120	5000	1760000000	3469	5000	1760000000' 1760000000)"
eq "a stale cache is not" "" "$(budget_cached '1759999900	4120	5000	1760000000	3469	5000	1760000000' 1760000000)"
eq "an empty cache is not" "" "$(budget_cached '' 1760000000)"
eq "the budget is one line" "GraphQL 4,120 of 5,000 left, resets 09:19Z (in 23 min); REST 3,469 of 5,000 left." "$(budget_line "4120	5000	1760001540	3469	5000	1760001540" 1760000200)"
# issue-open.sh passes each label as one argument, spaces and all.
io_dir=$(mktemp -d)
mkdir -p "$io_dir/bin"
# The fake gh lists the project's labels in the spaced form, and files.
printf '#!/bin/sh\ncase "$*" in *labels?per_page*) printf "bug\\nstate: ready\\nstate: in progress\\n"; exit 0 ;; esac\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done > "%s/args"\nprintf "7\\thttps://example/7\\n"\n' "$io_dir" > "$io_dir/bin/gh"
chmod +x "$io_dir/bin/gh"
printf 'body\n' > "$io_dir/body.md"
io_out=$(PATH="$io_dir/bin:$PATH" sh "$root/templates/scripts/issue-open.sh" "A title" "$io_dir/body.md" "state: ready" bug 2>&1)
eq "a label with a space is filed as one label" "Filed issue #7: https://example/7 | [labels[]=state: ready] [labels[]=bug]" "$io_out | $(grep '^\[labels' "$io_dir/args" | tr '\n' ' ' | sed 's/ $//')"
io_out=$(PATH="$io_dir/bin:$PATH" sh "$root/templates/scripts/issue-open.sh" "A title" "$io_dir/body.md" state:in-progress 2>&1)
eq "a state label typed compact is filed in the project's spaced form" "[labels[]=state: in progress]" "$(grep '^\[labels' "$io_dir/args" | tr '\n' ' ' | sed 's/ $//')"
eq "a low budget says what to do" "GraphQL 312 of 5,000 left, resets 09:19Z (in 23 min); REST 3,469 of 5,000 left. Low: use the REST forms (scripts/issue-open.sh, pr-open.sh, pr-checks.sh, gh api) and wait for the reset; never retry before it." "$(budget_line "312	5000	1760001540	3469	5000	1760001540" 1760000200)"
eq "an escaped backtick in a body does not cut the command before its labels" "" "$(state_label_reason 'gh api repos/o/r/issues -f title="x" -f body="run \`node a.mjs\` (once)" -f "labels[]=state:in-progress" --jq .number; W=C:/w; git worktree add -q -b b $W origin/main')"
eq "nor an escaped semicolon outside quotes" "" "$(state_label_reason 'gh api repos/o/r/issues -f title=x -f body=a\;b -f labels[]=state:ready')"
eq "a real command substitution in double quotes is still seen" "rm" "$(split_commands 'echo "$(rm -rf x)"' | awk '{print $1}' | grep -x rm)"
eq "a budget getting low says so early" "GraphQL 1,200 of 5,000 left, resets 09:19Z (in 23 min); REST 3,469 of 5,000 left. Getting low: switch to the REST forms now (scripts/issue-open.sh, pr-open.sh, pr-checks.sh, gh api); gh pr, gh issue and gh project spend these points." "$(budget_line "1200	5000	1760001540	3469	5000	1760001540" 1760000200)"
eq "every fetch of main goes through the retry" "0 3" "$(grep -c '^[[:space:]]*git fetch -q origin "\$base"\( "pull\|$\)' "$root/templates/scripts/ci/merge-queue.sh") $(grep -c 'fetch_base' "$root/templates/scripts/ci/merge-queue.sh" | awk '{print ($1 >= 3) ? 3 : $1}')"
eq "a round that could not fetch main puts its pull requests back" "1" "$(grep -c 'case " \$untried " in' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the queue waits only on the REST budget it spends" "1" "$(grep -c "rate_limit --jq '.resources.core |" "$root/templates/scripts/ci/merge-queue.sh")"
eq "no record, no line" "" "$(budget_line '' 1760000200)"
eq "under the floor is low" "yes" "$(budget_low "312	5000	1760001540	3469	5000	1760001540")"
eq "at the floor is not" "no" "$(budget_low "500	5000	1760001540	3469	5000	1760001540")"
eq "an unknown budget is not low" "no" "$(budget_low '')"
eq "a REST issue without its State label is named" "gh api .../issues" "$(state_label_reason 'gh api -X POST repos/{owner}/{repo}/issues -f title="Fix" -F body=@.scratch/b.md')"
eq "a REST issue with labels[]=state: passes" "" "$(state_label_reason "gh api -X POST repos/{owner}/{repo}/issues -f title='Fix' -f 'labels[]=state:ready'")"
eq "a REST issue from --input passes" "" "$(state_label_reason 'gh api -X POST repos/{owner}/{repo}/issues --input .scratch/issue.json')"
eq "a REST read of an issue is not a create" "" "$(state_label_reason 'gh api repos/{owner}/{repo}/issues/12 --jq .title')"
eq "a comment on an issue is not a create" "" "$(state_label_reason 'gh api -X POST repos/{owner}/{repo}/issues/12/comments -f body=hi')"
eq "a low API budget is one line" "GitHub API budget: 312 of 5000 left; resets in 41 minute(s). Poll slowly (30s or more) and run one queue at a time." "$(rate_line "312	5000	3460" 1000)"
eq "no API budget says so" "GitHub API budget: none left of 5000; resets in 10 minute(s). Do not poll; run the queue with --drain after that." "$(rate_line "0	5000	1600" 1000)"
eq "a healthy API budget is silent" "" "$(rate_line "4800	5000	1600" 1000)"
eq "an unknown API budget is silent" "" "$(rate_line '' 1000)"
eq "newest handoff, ignoring other notes" "/mem/handoff-2026-10-02.md" "$(newest_handoff "$(cat "$fx/handoff-listing.tsv")")"
eq "no handoff files, nothing" "" "$(newest_handoff "$(printf '1\t/mem/notes.md\n')")"
eq "handoff head skips front matter" "The batch queue PR is open and waiting on one full run.
Next: merge it, then run the serial queue for #45, which conflicted." "$(handoff_head "$(cat "$fx/handoff-2026-10-02.md")" 2)"
eq "trim within the limit" "a
b" "$(trim_section 'a
b' 5)"
eq "trim past the limit says how many" "a
b
(and 2 more)" "$(trim_section 'a
b
c
d' 2)"
eq "a clear prints the short form" "main inprogress" "$(brief_sections clear)"
eq "a startup prints everything" "main prs queue inprogress leftover screens handoff owner proposal" "$(brief_sections startup)"
facts=$(cat "$fx/board-facts.tsv")
eq "pr lines from the one-call facts" "#41 Add retries (mergeable, CI green)
#42 Fix the parser (has conflicts, CI red)
#45 Rename the page (mergeability unknown, CI running)
#47 Docs only (mergeable, no CI yet)" "$(pr_brief_lines "$facts" 10)"
eq "pr lines past the limit are counted" "#41 Add retries (mergeable, CI green)
(and 3 more)" "$(pr_brief_lines "$facts" 1)"
eq "state from labels, either spelling" "in-progress in-progress none" "$(printf '%s %s %s' "$(state_of_labels 'task,state:in-progress')" "$(state_of_labels 'state: in progress')" "$(state_of_labels 'bug,task')")"
eq "issues grouped by state, long lists counted" "Issues: 57 open. 3 ready, 2 in progress, 1 waiting on owner, 1 parked, 1 no state (first 8 read)
In progress:
#20 Billing
#21 Search
Owner actions waiting:
#30 Choose the logo
Ready:
#12 Add the exporter
#13 Set the price of the plan
#77 main is red" "$(issues_summary "$facts")"
eq "no issues, no summary" "" "$(issues_summary 'pr	1	x	NONE	MERGEABLE	b	')"
eq "leftover work from one local listing" "Leftover work: 2 of 4 local branches have commits not on main.
retries (3)
rename (1)" "$(leftover_summary "$(printf 'main\t0 0\nretries\t3 12\nparser\t0 4\nrename\t1 0\n')" 5)"
eq "nothing ahead, nothing said" "" "$(leftover_summary "$(printf 'main\t0 0\nparser\t0 4\n')" 5)"
porcelain=$(cat "$fx/worktrees.porcelain")
eq "worktrees counted with their folders, the agent runtime's apart" "Worktrees: 2 besides the main checkout, in 1 folder, and 2 made by Claude Code for dispatched agents in .claude/worktrees." "$(worktree_summary "$porcelain")"
eq "only the main checkout, nothing said" "" "$(worktree_summary 'worktree /repo
branch refs/heads/main')"

printf '\n# the queue runs a test file with its own runner\n'
rt="$root/templates/scripts/ci/run-test-file.mjs"; rtf="$fx/test-runner"
eq "a node:test file is picked up by node --test" "node" "$(node "$rt" --which "$rtf/node-test/a.test.js" | tr -d '\r')"
eq "a node:test file runs and passes" "0" "$(node "$rt" "$rtf/node-test/a.test.js" >/dev/null 2>&1; echo $?)"
eq "a vitest file is still run by vitest" "vitest" "$(node "$rt" --which "$rtf/vitest/a.test.ts" | tr -d '\r')"
eq "an unknown runner is told as unknown" "unknown" "$(node "$rt" --which "$rtf/unknown/a.test.ts" | tr -d '\r')"
eq "an unknown runner is not run, never red" "3" "$(node "$rt" "$rtf/unknown/a.test.ts" >/dev/null 2>&1; echo $?)"
eq "the queue reports a file not run here" "1" "$(grep -c 'not run here:' "$root/templates/scripts/ci/merge-queue.sh")"

printf '\n# reading a run\n'
. "$root/templates/scripts/ci/run-lib.sh"
# --- Spec 001: the queue publishes its state.
. "$root/templates/scripts/ci/publish-lib.sh"
po_open="$(printf '12\tAdd retries\tgreen\tgreen and waiting to merge\n13\tFix the chime\twaiting\tstill running CI\n14\tRename\tred\tred; the queue re-runs its failed jobs once, then names it here')"
po_say=$(publish_say "$po_open" "" "" "" "" "$(printf '2\t1\t0\t0')" "" draining "")
eq "the doing sentence for a drain" "The queue is running, looking for green pull requests to merge." "$(printf '%s\n' "$po_say" | sed -n 1p)"
eq "the waiting sentence counts each state" "3 pull requests are open: 1 is green and waiting to merge (#12); 1 is still running CI; 1 is red (#14)." "$(printf '%s\n' "$po_say" | sed -n 2p)"
eq "nothing needs a person" "Nothing needs you." "$(printf '%s\n' "$po_say" | sed -n 3p)"
eq "a batch says its members and the time left" "Testing a batch of 3 pull requests together (#12, #13 and #15); about 6 minutes left, 2 of 2 runners busy." "$(publish_say "$po_open" "$(printf '20\t12 13 15\t12\t2\t4\t6')" "" "" "" "$(printf '2\t2\t0\t0')" "" draining "" | sed -n 1p)"
eq "a local build says its progress" "Building a batch of 4 pull requests on the queue's own machine: 3 merged, checking #909." "$(publish_say "" "" "3 4 909 905 906 907 909" "" "" "" "" batch "" | sed -n 1p)"
eq "a clash names the files and that the owner was told" "Nothing is waiting. #252 was left out: it clashes with #249 in src/lib/dates.ts, and its owner has been told." "$(publish_say "" "" "" "$(printf '252\t249\tsrc/lib/dates.ts\tyes')" "" "" "" idle "" | sed -n 2p)"
eq "what needs a person is said with its error line" "Needs you: #14 failed CI twice: FAIL  the chime rings." "$(publish_say "" "" "" "" "$(printf '14\tfailed CI twice\tits checks stay red\tFAIL  the chime rings')" "" "" idle "" | sed -n 3p)"
eq "no runner online is said" "No runner is online, so nothing can be tested; start one." "$(publish_say "" "" "" "" "" "$(printf '0\t0\t2\t15')" "" idle "" | sed -n 3p)"
eq "paused says until when" "The scheduled queue is paused until 2026-10-22T20:00:00Z; a drain run by hand still runs." "$(publish_say "" "" "" "" "" "" "" paused 2026-10-22T20:00:00Z | sed -n 1p)"
po_json=$(publish_json "$po_open" "" "3 4 909 905 906 907 909" "$(printf '252\t249\tsrc/lib/dates.ts\tyes')" "$(printf '11\tFirst\tserial\t2026-10-22T18:00:00Z')" "$(printf '2\t1\t0\t0')" "" "$(printf 'abc1234\tgreen')" "deploy: due; none recorded" draining "" "12 13" "$po_say" 2026-10-22T19:00:00Z)
eq "the JSON parses and carries the version" "1" "$(printf '%s' "$po_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.version)})')"
eq "the JSON's say matches the sentences" "yes" "$(printf '%s' "$po_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.say.waiting.startsWith("3 pull requests are open")&&j.open.length===3&&j.open[2].state==="red"&&j.building.current===909&&j.clashes[0].files[0]==="src/lib/dates.ts"&&j.landed[0].number===11&&j.checking[1]===13&&j.main.state==="green"?"yes":"no")})')"
eq "a quote and a newline in a title survive" '"say \"hi\"\nthere"' "$(json_str "$(printf 'say "hi"
there')")"
po_body=$(publish_body "$po_say" "$po_open" "" "" "$po_json" yes)
eq "the first body explains the queue" "1" "$(printf '%s\n' "$po_body" | grep -c "This issue is the merge queue's own page")"
eq "a later body does not" "0" "$(publish_body "$po_say" "$po_open" "" "" "$po_json" no | grep -c "own page")"
eq "the body lists each open pull request with its sentence" "- #12 Add retries: green and waiting to merge" "$(printf '%s\n' "$po_body" | grep '^- #12')"
eq "the JSON block is read back out of the body" "yes" "$(published_json "$po_body" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).version===1?"yes":"no")})')"
eq "the queue publishes as it drains and at its end" "2" "$(grep -c 'publish_now draining\|publish_now idle' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the drain workflow may write issues" "1" "$(grep -c '^  issues: write' "$root/templates/.github/workflows/queue-drain.yml")"
eq "the queue label exists" "1" "$(grep -c 'mk "queue"' "$root/templates/scripts/labels.sh")"

printf '\n# the queue on the service road (spec 006)\n'
sv_waits="$(printf '1000\t-\tci / unit\t3\t3\t4\n1100\t-\tci / app\t1\t3\t2\n10\t-\told job\t1\t1\t9')"
eq "the wait lines are the jobs since the cutoff, in seconds, with why" '[{"job":"ci / unit","waitedSeconds":240,"why":"all 3 runners were busy"},{"job":"ci / app","waitedSeconds":120,"why":"1 of 3 runners were busy"}]' "$(service_waits_json "$sv_waits" 500)"
eq "no waits is an empty list" '[]' "$(service_waits_json "" 0)"
eq "the body is spec 001's state with the wait lines added" '{"version":1,"mode":"idle","waits":[]}' "$(service_body '{"version":1,"mode":"idle"}' '[]')"
eq "the body of a real state still parses, version 1" "yes" "$(service_body "$po_json" "$(service_waits_json "$sv_waits" 0)" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.version===1&&j.waits.length===3?"yes":"no")})')"
eq "204 is a send that worked" "ok" "$(service_outcome 204)"
eq "401 is not connected" "not_connected" "$(service_outcome 401)"
eq "413 is too large" "too_large" "$(service_outcome 413)"
eq "429 is dropped quietly" "rate_limited" "$(service_outcome 429)"
eq "a 5xx is unreachable" "unreachable" "$(service_outcome 503)"
eq "no answer at all is unreachable" "unreachable" "$(service_outcome 000)"
eq "failing under an hour leaves the issue alone" "no" "$(service_issue_too 1000 4599)"
eq "failing for an hour writes the issue as well" "yes" "$(service_issue_too 1000 4600)"
eq "no failure writes no issue" "no" "$(service_issue_too "" 99999)"

# The whole script, with gh and curl stubbed: no network.
sv=$(mktemp -d); mkdir -p "$sv/bin" "$sv/q"
cat > "$sv/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "$SV_LOG"
case "$*" in *"issues?labels=queue"*) printf '5\topen\n' ;; esac
exit 0
GH
cat > "$sv/bin/curl" <<'CURL'
#!/bin/sh
cat > /dev/null
printf 'curl %s\n' "$*" >> "$SV_LOG"
printf '%s' "$SV_STATUS"
CURL
chmod +x "$sv/bin/gh" "$sv/bin/curl"
sv_run() {
  # Each run is a new state, as a drain's changes are.
  [ -f "$sv/q/published.sig" ] && mv "$sv/q/published.sig" "$sv/q/published.sig.prev"
  ( cd "$sv" && PATH="$sv/bin:$PATH" SV_LOG="$sv/log" SV_STATUS="$1" QUEUE_PUBLISH_STATE=service SIPNSHIP_REPO_TOKEN=sns_repo_test SIPNSHIP_REPO_ID=7 SIPNSHIP_URL=http://127.0.0.1:9 QUEUE_DIR="$sv/q" SIPNSHIP_HOME="$sv/home" \
    sh "$root/templates/scripts/ci/publish-state.sh" --mode idle 2>/dev/null )
}
: > "$sv/q/service.moved"
: > "$sv/log"; sv_out=$(sv_run 204)
eq "under service a send that works posts /queue" "1" "$(grep -c '^curl .*/v1/repos/7/queue' "$sv/log")"
eq "and does not write the issue" "0" "$(grep -c 'issues/5' "$sv/log")"
eq "and says nothing" "" "$sv_out"
: > "$sv/log"; printf '%s\n' "$(( $(date +%s) - 120 ))" > "$sv/q/service.failing-since"; sv_out=$(sv_run 503)
eq "a failed send says one line" "1" "$(printf '%s\n' "$sv_out" | grep -c 'Could not reach SipNShip')"
eq "a failed send under an hour does not write the issue" "0" "$(grep -c 'issues/5' "$sv/log")"
: > "$sv/log"; sv_out=$(sv_run 503)
eq "the failure is said once" "" "$sv_out"
: > "$sv/log"; printf '%s\n' "$(( $(date +%s) - 3700 ))" > "$sv/q/service.failing-since"; sv_out=$(sv_run 503)
eq "after an hour of failed sends the queue writes its issue as well" "1" "$(grep -c 'PATCH repos/{owner}/{repo}/issues/5 -F body' "$sv/log")"
: > "$sv/log"; rm_sig="$sv/q/published.sig"; mv "$rm_sig" "$rm_sig.old" 2>/dev/null; sv_out=$(sv_run 204)
eq "a send that works again stops the issue writes" "0" "$(grep -c 'issues/5' "$sv/log")"
eq "and clears the failing clock" "" "$(cat "$sv/q/service.failing-since")"
mv "$sv/q/published.sig" "$sv/q/published.sig.2" 2>/dev/null
: > "$sv/log"; sv_out=$( cd "$sv" && PATH="$sv/bin:$PATH" SV_LOG="$sv/log" SV_STATUS=204 QUEUE_PUBLISH_STATE=service SIPNSHIP_REPO_TOKEN= SIPNSHIP_REPO_ID= QUEUE_DIR="$sv/q" SIPNSHIP_HOME="$sv/home" sh "$root/templates/scripts/ci/publish-state.sh" --mode idle 2>/dev/null )
eq "with no token the queue writes the issue as before" "1" "$(grep -c 'PATCH repos/{owner}/{repo}/issues/5 -F body' "$sv/log")"
eq "and says so once" "1" "$(printf '%s\n' "$sv_out" | grep -c 'not connected to SipNShip')"
eq "and sends nothing" "0" "$(grep -c '^curl' "$sv/log")"
eq "the queue's copy and the template are the same" "same" "$(cmp -s "$root/templates/scripts/ci/publish-state.sh" "$root/../scripts/ci/publish-state.sh" 2>/dev/null && echo same || { [ -f "$root/../scripts/ci/publish-state.sh" ] || echo same; })"
mv "$sv" "$sv.done" 2>/dev/null || true
eq "the runner count defaults to three" "3" "$(runner_count '')"
eq "and reads the project's number" "4" "$(runner_count '{ "runners": 4 }')"
eq "all online, in one line" "3 of 3 online" "$(runner_status "$(printf 'a\tonline\tfalse\nb\tonline\ttrue\nc\tonline\tfalse')" 3)"
eq "one offline, named" "2 of 3 online; c offline" "$(runner_status "$(printf 'a\tonline\tfalse\nb\tonline\ttrue\nc\toffline\tfalse')" 3)"
eq "fewer registered than wanted" "2 of 3 wanted are registered; 2 online" "$(runner_status "$(printf 'a\tonline\tfalse\nb\tonline\tfalse')" 3)"
eq "a quiet machine says nothing" "" "$(load_verdicts "$(printf '20\t40\t135\t1\t1\t9\t32')" 3)"
eq "jobs waiting on an idle machine want a runner" "idle-wait|jobs waited 14 minutes on average and the processor was 30% busy; one more runner would help" "$(load_verdicts "$(printf '30\t40\t135\t2\t14\t9\t32')" 3)"
eq "jobs waiting on a saturated machine do not" "saturated|jobs waited 9 minutes on average while the processor was 92% busy with 5 running; more runners would make each job slower: fewer runners, or a second machine" "$(load_verdicts "$(printf '92\t60\t135\t5\t9\t9\t32')" 3)"
eq "low disk is urgent under five" "disk-urgent|only 4 GB free on the runners' drive; a checkout can fail any time" "$(load_verdicts "$(printf '10\t40\t4\t0\t0\t9\t32')" 3)"
eq "too many runners for the cores" "overcommit|20 runners on 32 cores across the projects on this machine; past one runner per two cores each job slows the others" "$(load_verdicts "$(printf '10\t40\t100\t0\t0\t20\t32')" 3)"
eq "the watch says a condition once when it starts" "started: b" "$(watch_changes "$(printf 'x|a')" "$(printf 'x|a\ny|b')")"
eq "and once when it ends" "ended: a" "$(watch_changes "$(printf 'x|a')" '')"
eq "every thirty minutes is 1,440 a month" "1440" "$(cron_runs_month '*/30 * * * *')"
eq "every two hours is 360" "360" "$(cron_runs_month '17 */2 * * *')"
eq "nightly is 30" "30" "$(cron_runs_month '17 3 * * *')"
eq "a hosted job is found, with its schedule and events" "$(printf '.github/workflows/x.yml\t41 */6 * * *\tissues')" "$(hosted_jobs .github/workflows/x.yml "$(printf 'on:\n  schedule:\n    - cron: \"41 */6 * * *\"\n  issues:\njobs:\n  w:\n    runs-on: ubuntu-latest\n')")"
eq "a permissions line is not a trigger" "$(printf 'x.yml\t\t')" "$(hosted_jobs x.yml "$(printf 'on:\n  workflow_dispatch:\npermissions:\n  issues: write\njobs:\n  w:\n    runs-on: ubuntu-latest\n')")"
eq "a job gated on a variable is not counted" "" "$(hosted_jobs x.yml "$(printf 'jobs:\n  w:\n    if: vars.RUNNER_WATCH_HOSTED == '"'"'yes'"'"'\n    runs-on: ubuntu-latest\n')")"
eq "a self-hosted job is not hosted" "" "$(hosted_jobs x.yml "$(printf 'jobs:\n  w:\n    runs-on: [self-hosted, windows]\n')")"
eq "the estimate adds the schedules" "hosted Actions: queue-drain, audit run hosted in this private repository, about 1,470 scheduled minutes a month plus audit once per issues; the free allowance is 2,000 and is shared by every repository on the account" "$(hosted_estimate "$(printf '.github/workflows/queue-drain.yml\t*/30 * * * *\t\n.github/workflows/audit.yml\t17 3 * * *\tissues')")"
eq "no hosted job, no line" "" "$(hosted_estimate '')"
eq "the watch task runs headless through sh -c with a log" "1" "$(grep -c 'conhost.exe" -Argument "--headless .* -c ' "$root/templates/scripts/ci/runner-watch-install.ps1")"
eq "there is no hosted runner watch in the templates" "no" "$([ -f "$root/templates/.github/workflows/runner-watch.yml" ] && echo yes || echo no)"
eq "the quota annotation says one plain line" "1" "$(quota_gone 'The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the Billing settings.' | wc -l | tr -d ' ')"
eq "and it names the variable that skips hosted jobs" "1" "$(quota_gone 'your spending limit needs to be increased' | grep -c 'gh variable set HOSTED_MINUTES --body gone')"
eq "any other annotation says nothing" "" "$(quota_gone 'Process completed with exit code 1.')"
eq "no annotation says nothing" "" "$(quota_gone '')"
eq "the quota guard does not hide a hosted job from the estimate" "$(printf 'x.yml		deployment_status')" "$(hosted_jobs x.yml "$(printf 'on:
  deployment_status:
jobs:
  w:
    if: vars.HOSTED_MINUTES != '"'"'gone'"'"' && github.event_name == '"'"'x'"'"'
    runs-on: ubuntu-latest
')")"
eq "the smoke check skips when hosted minutes are gone" "1" "$(grep -c "if: vars.HOSTED_MINUTES != 'gone' && " "$root/templates/.github/workflows/smoke.yml")"
eq "the audit reads the quota annotation" "1" "$(grep -c 'quota=\$(quota_gone' "$root/templates/.github/workflows/audit.yml")"
eq "the audit says when a run sits queued" "1" "$(grep -c 'stuck=\$(stuck_runs' "$root/templates/.github/workflows/audit.yml")"
eq "a queued run is one brief line" "Queued: CI on main has waited 14 minutes for a runner, and 1 more; start the runners (scripts/ci/RUNNERS.md)." "$(stuck_line "$(stuck_runs "$(printf '1\tCI\tmain\tqueued\t1060\n2\tAudit\tmain\tqueued\t1200\n')" 1900 10)")"
eq "nothing queued, no line" "" "$(stuck_line '')"
eq "the brief names a run queued over ten minutes" "1" "$(grep -c 'stuck_line "$(stuck_runs' "$root/hooks/scripts/session-brief.sh")"
eq "green run" "green" "$(run_verdict "$(printf 'build\tcompleted\tsuccess\t1000\t\ntest\tcompleted\tskipped\t1000\t\n')" 2000)"
eq "pending run" "pending" "$(run_verdict "$(printf 'build\tin_progress\t\t1000\t\n')" 2000)"
eq "failed run names the job" "failed: test, lint" "$(run_verdict "$(printf 'build\tcompleted\tsuccess\t1\t\ntest\tcompleted\tfailure\t1\t\nlint\tcompleted\tfailure\t1\t\n')" 2000)"
eq "canceled run" "canceled: test" "$(run_verdict "$(printf 'test\tcompleted\tcancelled\t1\t\n')" 2000)"
eq "outage by annotation" "outage: build: The job was not acquired by Runner of type hosted" "$(run_verdict "$(printf 'build\tqueued\t\t1000\tThe job was not acquired by Runner of type hosted\n')" 1100)"
eq "a billing refusal is its own verdict, before the outage" "billing: deploy" "$(run_verdict "$(printf 'deploy\tcompleted\tfailure\t1000\tThe job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the Billing & plans section in your settings\nplan\tqueued\t\t1000\tThe job was not acquired by Runner of type hosted\n')" 1100)"
eq "billing_refused reads the annotation" "yes" "$(billing_refused 'The job was not started because recent account payments have failed or your spending limit needs to be increased.')"
eq "and not a plain failure" "" "$(billing_refused 'Process completed with exit code 1.')"
eq "the billing line names what could not start, once, plainly" "1" "$(billing_line 'the Deploy workflow' | grep -c '^Hosted Actions minutes are used up: GitHub refused to start the Deploy workflow for billing')"
eq "outage by a long queue while our runners idle" "outage: build: queued for 10 minutes while 2 of our runners were idle" "$(run_verdict "$(printf 'build\tqueued\t\t1000\t\n')" 1600 2)"
eq "a long queue with no idle runner is just pending" "pending" "$(run_verdict "$(printf 'build\tqueued\t\t1000\t\n')" 1600 0)"
eq "githubstatus degraded" "GitHub Actions: degraded_performance" "$(githubstatus_verdict '{"components":[{"name":"Git Operations","status":"operational"},{"name":"Actions","status":"degraded_performance"}]}')"
eq "githubstatus fine" "" "$(githubstatus_verdict '{"components":[{"name":"Actions","status":"operational"}]}')"
eq "githubstatus empty" "" "$(githubstatus_verdict '')"
eq "failing tests from three runner formats" "src/preview.test.tsx > renders the preview
tests/test_a.py::test_x
TestParse" "$(failed_tests_from_log "$(printf ' FAIL  src/preview.test.tsx > renders the preview 120ms\n   ok other\nFAILED tests/test_a.py::test_x - assert 1 == 2\n--- FAIL: TestParse (0.00s)\n FAIL  src/preview.test.tsx > renders the preview\n')")"
flog=$(flaky_log_add '' 2026-10-05 41 'src/preview.test.tsx > renders' failed)
flog=$(flaky_log_add "$flog" 2026-10-05 41 'src/preview.test.tsx > renders' passed)
flog=$(flaky_log_add "$flog" 2026-10-05 42 'src/preview.test.tsx > renders' failed)
flog=$(flaky_log_add "$flog" 2026-10-05 42 'src/preview.test.tsx > renders' passed)
flog=$(flaky_log_add "$flog" 2026-10-05 43 'src/other.test.ts > once' failed)
flog=$(flaky_log_add "$flog" 2026-10-05 43 'src/other.test.ts > once' passed)
flog=$(flaky_log_add "$flog" 2026-10-05 44 'src/real.test.ts > broken' failed)
eq "the log grows one line at a time" "7" "$(printf '%s\n' "$flog" | wc -l | tr -d ' ')"
eq "offenders: failed then passed, twice, with their PRs" "2	src/preview.test.tsx > renders	41,42" "$(flaky_offenders "$flog" 2)"
eq "one flake is not yet an offender, a plain failure never is" "1	src/other.test.ts > once	43
2	src/preview.test.tsx > renders	41,42" "$(flaky_offenders "$flog" 1 | sort -t'	' -k2)"
eq "main in flight" "yes" "$(main_in_flight "$(printf '1\tmain\tin_progress\tpush\n2\tfeature\tqueued\tpull_request\n')")"
eq "main quiet" "no" "$(main_in_flight "$(printf '1\tmain\tcompleted\tpush\n2\tfeature\tin_progress\tpull_request\n')")"

printf '\n# runner doctor\n'
. "$root/templates/scripts/ci/doctor-lib.sh"
eq "WSL bash on PATH warns" "warn" "$(bash_verdict 'C:\Windows\System32\bash.exe')"
eq "Git bash is fine" "ok" "$(bash_verdict '/c/Program Files/Git/usr/bin/bash')"
eq "no bash warns" "warn" "$(bash_verdict '')"
eq "a tool whose folder is on the machine PATH" "ok" "$(tool_on_machine_path '/c/Program Files/nodejs/node' 'C:\Windows;C:\Program Files\nodejs\;C:\Program Files\Git\cmd')"
eq "a tool missing from the machine PATH" "warn" "$(tool_on_machine_path '/c/Users/me/AppData/Roaming/npm/node' 'C:\Windows;C:\Program Files\Git\cmd')"
eq "a restricted machine policy warns" "warn" "$(policy_verdict 'MachinePolicy=Undefined UserPolicy=Undefined Process=Undefined CurrentUser=Undefined LocalMachine=Restricted')"
eq "an open policy is fine" "ok" "$(policy_verdict 'MachinePolicy=Undefined LocalMachine=RemoteSigned')"
eq "a shell that sets NoDefaultCurrentDirectoryInExePath warns" "warn" "$(exepath_verdict 1)"
eq "a shell that does not set it is fine" "ok" "$(exepath_verdict '')"

printf '\n# board digest\n'
. "$root/scripts/board/board-lib.sh"
dfacts=$(cat "$fx/board-facts-dated.tsv")
ddigest=$(cat "$fx/board-digest.tsv")
eq "open items with their last-updated time" "41	pr	2026-10-04T10:00:00Z	Add retries
12	issue	2026-10-03T09:00:00Z	Add the exporter" "$(open_items "$dfacts" | head -n 2)"
eq "only items with a missing or older summary are changed" "12	issue
30	issue" "$(changed_items "$dfacts" "$ddigest")"
eq "with no digest everything is changed" "6" "$(changed_items "$dfacts" '' | wc -l | tr -d ' ')"
eq "freshness counts current over open" "4	6" "$(digest_freshness "$dfacts" "$ddigest")"
merged=$(merge_digest "$ddigest" '12 | Agent | start the exporter | - | Ready to build; nothing decided yet.
30 | agent | use option B | - | The owner chose B.
77 | agent | not open | - | Should be ignored.
garbage line' "$dfacts")
eq "merge keeps open items, replaces the re-read, drops the closed" "6" "$(printf '%s\n' "$merged" | wc -l | tr -d ' ')"
eq "a re-read item is stamped with its current time" "30	issue	2026-10-04T11:30:00Z	agent	use option B	-	The owner chose B." "$(printf '%s\n' "$merged" | grep '^30	')"
eq "a new item is added with its kind and time" "12	issue	2026-10-03T09:00:00Z	agent	start the exporter	-	Ready to build; nothing decided yet." "$(printf '%s\n' "$merged" | grep '^12	')"
eq "a closed item drops out and an unknown one is ignored" "" "$(printf '%s\n' "$merged" | grep -E '^(99|77)	')"
eq "after the merge everything is current" "6	6" "$(digest_freshness "$dfacts" "$merged")"
eq "batches of paths for readers" "a b
c" "$(batch_paths 'a
b
c' 2)"
eq "the brief's lines: who has the ball, owner first" "#30 Choose the logo: ball owner; next owner picks a logo (changed since)
#31 Pick the price: ball agent; next set the price to 48 and continue
#40 Mail is bouncing: ball service; next wait for the mail provider; blocked by the provider's outage
#20 Billing: ball owner; next owner picks monthly or yearly first
#41 Add retries: ball reviewer; next review and merge" "$(digest_brief_lines "$dfacts" "$ddigest" 8)"
eq "the brief's lines are counted past the limit" "#30 Choose the logo: ball owner; next owner picks a logo (changed since)
(and 4 more in the digest)" "$(digest_brief_lines "$dfacts" "$ddigest" 1)"
eq "goals labels alone would miss, from current summaries only" "mark-waiting 20	Billing (a question to the owner is open)
set-ready 31	Pick the price (the owner answered)" "$(digest_goals "$dfacts" "$ddigest")"
eq "no digest, no extra goals" "" "$(digest_goals "$dfacts" '')"

printf '\n# clean endings (hook library)\n'
. "$root/hooks/scripts/worktree-lib.sh"
status=' M scripts/upload.sh
?? tests/admin.test.ts
?? .scratch/probe.mjs
?? shots/a.png
?? shots/b.JPG
R  old.md -> docs/new.md'
eq "dirty files outside the scratch folder" "scripts/upload.sh
tests/admin.test.ts
shots/a.png
shots/b.JPG
docs/new.md" "$(dirty_non_scratch "$status")"
eq "only scratch is clean" "" "$(dirty_non_scratch '?? .scratch/notes.md
?? .scratch/')"
eq "a clean tree is clean" "" "$(dirty_non_scratch '')"
eq "images and build output counted" "3" "$(stray_media 'shots/a.png
shots/b.JPG
src/a.ts
dist/')"
eq "no media, zero" "0" "$(stray_media 'src/a.ts')"
eq "processes started from the folder" "412	node C:\\Users\\me\\wt\\task\\node_modules\\next\\dist\\bin\\next start" "$(procs_in_dir "$(printf '412\tnode C:\\Users\\me\\wt\\task\\node_modules\\next\\dist\\bin\\next start\n77\tnode D:/other/server.js\n90\tsh C:/Users/me/wt/task/../hooks/scripts/session-brief.sh\n')" 'C:/Users/me/wt/task')"
eq "a three-column list works too" "412	sh scripts/ci/design-check.sh C:/Users/me/wt/task" "$(procs_in_dir "$(printf '412\t300\tsh scripts/ci/design-check.sh C:/Users/me/wt/task\n')" 'C:/Users/me/wt/task')"
plist=$(printf '1\t0\twininit\n100\t1\tC:\\app\\claude.exe\n101\t100\tnode mcp-server.js\n102\t100\tbash -c "source /c/Users/me/.claude/shell-snapshots/snap.sh; eval sh scripts/ci/design-check.sh"\n103\t102\tsh scripts/ci/design-check.sh\n104\t100\tsh C:/plugin/hooks/scripts/require-clean-worktree.sh\n105\t100\tsleep 90\n200\t1\tC:\\app\\claude.exe\n201\t200\tsh scripts/other.sh\n300\t1\tnode D:/other/server.js\n')
eq "scripts this session started, by ancestry, not the hooks, the servers or another session" "102	bash -c \"source /c/Users/me/.claude/shell-snapshots/snap.sh; eval sh scripts/ci/design-check.sh\"
103	sh scripts/ci/design-check.sh" "$(session_procs "$plist" 104)"
eq "no claude ancestor, nothing" "" "$(session_procs "$plist" 300)"
eq "an orphaned script names its relative path" "500	sh scripts/ci/design-check.sh	scripts/ci/design-check.sh
501	node ./scripts/design/generate.mjs --check	scripts/design/generate.mjs" "$(orphan_scripts "$(printf '1\t0\twininit\n500\t999\tsh scripts/ci/design-check.sh\n501\t998\tnode ./scripts/design/generate.mjs --check\n502\t997\tsleep 90\n503\t1\tsh scripts/live.sh\n')")"
eq "no process in the folder" "" "$(procs_in_dir "$(printf '77\tnode D:/other/server.js\n')" '/home/me/wt/task')"
eq "closing a PR with no comment" "gh pr close" "$(pr_close_reason 'gh pr close 41')"
eq "closing with a comment is fine" "" "$(pr_close_reason 'gh pr close 41 --comment "replaced by #52"')"
eq "closing with -c is fine" "" "$(pr_close_reason 'gh pr close 41 -c "duplicate of #40"')"

printf '\n# long_command_reason\n'
eq "a short titled command is fine" "" "$(long_command_reason 'git status' 'Show the working tree')"
eq "no description is named" "no description" "$(long_command_reason 'git status' '')"
eq "a whitespace description is no description" "no description" "$(long_command_reason 'git status' '  ')"
eq "too many lines is named by count" "14 lines" "$(long_command_reason "$(seq 1 14 | sed 's/^/echo /')" 'Echo fourteen lines')"
eq "too many characters is named by count" "1200 characters" "$(long_command_reason "$(head -c 1200 /dev/zero | tr '\0' 'x')" 'A long one')"
eq "the limits can be set" "3 lines" "$(long_command_reason 'a
b
c' 'Three' 2)"
eq "a long quoted body is not counted" "" "$(long_command_reason "gh api -X POST repos/o/r/pulls -f title=x -f body=\"$(head -c 1500 /dev/zero | tr '\0' 'y')\"" 'Open the pull request')"
eq "a long quoted body with newlines is not counted" "" "$(long_command_reason "gh api -f body=\"$(seq 1 30 | tr '\n' ' ' | sed 's/ /\
/g')\"" 'Open it')"
eq "a long program in a heredoc still counts" "14 lines" "$(long_command_reason "python - <<'EOF'
$(seq 1 12 | sed 's/^/print(/; s/$/)/')
EOF" 'Run it')"
eq "a rate limit is a refusal, not a sign-out" "yes" "$(gh_refusal 'GraphQL: API rate limit exceeded for user ID 1')"
eq "unknown owner type is a refusal" "yes" "$(gh_refusal 'unknown owner type: someone')"
eq "a sign-out is not" "no" "$(gh_refusal 'You are not logged into any GitHub hosts')"

printf '\n# daemon_stop_reason\n'
eq "gradlew --stop is refused" "gradlew --stop" "$(daemon_stop_reason './gradlew --stop')"
eq "the Windows wrapper too" "gradlew --stop" "$(daemon_stop_reason 'cd android && .\gradlew.bat --stop')"
eq "gradle --stop is refused" "gradle --stop" "$(daemon_stop_reason 'gradle --stop')"
eq "nx reset is refused" "nx reset" "$(daemon_stop_reason 'npx nx reset')"
eq "dotnet build-server shutdown is refused" "dotnet build-server shutdown" "$(daemon_stop_reason 'dotnet build-server shutdown')"
eq "a build is fine" "" "$(daemon_stop_reason './gradlew assembleDebug')"
eq "the word in a string is fine" "" "$(daemon_stop_reason 'git commit -m "never run gradlew --stop"')"
eq "no runner on this machine, allowed" "" "$(daemon_stop_reason 'DAEMON_STOP_OK=1 ./gradlew --stop')"
eq "viewing a PR is fine" "" "$(pr_close_reason 'gh pr view 41')"
eq "a detached worktree" "detached" "$(worktree_add_reason 'git worktree add --detach ../wt/x HEAD')"
eq "a worktree with a branch is fine" "" "$(worktree_add_reason 'git worktree add -b task-x ../wt/x')"
eq "git branch -d is not a worktree add" "" "$(worktree_add_reason 'git branch -d old')"
wtpairs=$(printf '/w/a\tretries\n/w/b\tparser\n/w/c\trename\n/w/d\t\n')
eq "stale and detached worktrees counted" "1	1" "$(stale_worktrees "$wtpairs" 'retries' "$(printf 'retries\t1000000\nparser\t1000000\nrename\t1900000\n')" 2000000 3)"

printf '\n# worktrees\n'
. "$root/templates/scripts/worktrees-lib.sh"
pairs=$(worktree_branches "$porcelain")
eq "the worktree of a branch" "C:/Users/me/Documents/GitHub/app-parser" "$(worktree_for_branch "$pairs" parser)"
eq "no worktree for a branch" "" "$(worktree_for_branch "$pairs" nothing)"
eq "detached worktrees named" "C:/Users/me/Documents/GitHub/app/.claude/worktrees/loose" "$(detached_worktrees "$pairs")"
ends=$(printf 'merged\tretries\nclosed\tparser\nmerged\tgone\n')
eq "merged heads from ended pull requests" "retries
gone" "$(pr_ends "$ends" merged)"
eq "closed heads from ended pull requests" "parser" "$(pr_ends "$ends" closed)"
eq "merged local branches with no worktree" "old-fix" "$(mergeable_local_branches 'main
retries
old-fix
wip' 'main
retries
old-fix' "$pairs" main)"
eq "the queue's folder test matches the hook's" "scripts/upload.sh" "$(dirty_non_scratch ' M scripts/upload.sh
?? .scratch/x')"

printf '\n# shared code and ended branches\n'
shared='# comment
scripts/build/*
src/lib/*'
eq "shared code mixed with other work" "scripts/build/pack.mjs" "$(shared_mix_reason 'scripts/build/pack.mjs
packs/durer/index.json' "$shared")"
eq "only shared code is fine" "" "$(shared_mix_reason 'scripts/build/pack.mjs
src/lib/a.ts' "$shared")"
eq "no shared code is fine" "" "$(shared_mix_reason 'packs/durer/index.json' "$shared")"
eq "an empty list never fails" "" "$(shared_mix_reason 'scripts/build/pack.mjs
packs/x' '# nothing listed')"
eq "remote branches whose pull request ended" "retries
parser" "$(ended_remote_branches 'main
retries
parser
wip' 'retries
parser
main')"
eq "the audit counts ended branches" "2 branch(es) are still on the remote after their pull request merged or closed. Their worktrees, if any, are leftovers; run sh scripts/worktrees.sh audit locally.
- retries
- parser" "$(audit_comment '' '' '' 'retries
parser')"
eq "path and branch per worktree, main left out" "C:/Users/me/Documents/GitHub/app-retries	retries
C:/Users/me/Documents/GitHub/app-parser	parser
C:/Users/me/Documents/GitHub/app/.claude/worktrees/rename	rename
C:/Users/me/Documents/GitHub/app/.claude/worktrees/loose	" "$pairs"
eq "merged branches are prunable, detached never" "C:/Users/me/Documents/GitHub/app-retries
C:/Users/me/Documents/GitHub/app/.claude/worktrees/rename" "$(prunable_worktrees "$pairs" 'retries
rename
loose')"
eq "one branch only" "C:/Users/me/Documents/GitHub/app/.claude/worktrees/rename" "$(prunable_worktrees "$pairs" 'retries
rename' rename)"
eq "an unmerged branch is not prunable" "" "$(prunable_worktrees "$pairs" 'other')"
eq "places counted" "2 2" "$(worktree_places "$pairs" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

printf '\n# project drive\n'
. "$root/scripts/drive/drive-lib.sh"
snap=$(cat "$fx/drive-snapshot.tsv")
eq "a full proposal, in order" "merge-batch 41 42 45 46
fix-pr 47	Broken build
ask-owner 13	Set the price of the plan
dispatch 12	Add the exporter
defer 2 ready issue(s): no free runner this round
fix-main 77
audit Open issues with no State label: #33
restart-queue
stop: proposal ready for approval" "$(propose_round "$snap" 2 4)"
eq "two green PRs merge one by one" "merge 41
merge 42
stop: proposal ready for approval" "$(propose_round 'pr	41	A	green	mergeable	app
pr	42	B	green	mergeable	app' 2 4)"
eq "three green but only two app PRs merge one by one" "merge 41
merge 42
merge 46
stop: proposal ready for approval" "$(propose_round 'pr	41	A	green	mergeable	app
pr	42	B	green	mergeable	app
pr	46	Docs	green	mergeable	other' 2 4)"
eq "more runners, more starts, within the agent budget" "dispatch 12	Add the exporter
dispatch 14	Fix the date format
dispatch 15	Rework the search
stop: proposal ready for approval" "$(propose_round 'issue	12	Add the exporter	ready	no
issue	14	Fix the date format	ready	no
issue	15	Rework the search	ready	no' 4 3)"
eq "nothing to propose stops" "stop: nothing to propose" "$(propose_round 'queue	none' 2 4)"
eq "only owner waits stops with the reason" "stop: everything left waits on a person" "$(propose_round 'issue	30	Logo	waiting-on-owner	no' 2 4)"
eq "work in flight stops with the reason" "stop: work is in flight; nothing to propose until it lands" "$(propose_round 'pr	48	Running	pending	mergeable	app
issue	20	Billing	in-progress	no' 2 4)"
eq "a conflicting green PR is not proposed for merge" "stop: work is in flight; nothing to propose until it lands" "$(propose_round 'pr	49	Old	green	conflicting	app' 2 4)"
eq "proposal numbered, defer and stop unnumbered" "$(cat "$fx/drive-proposal.txt")" "$(number_proposal "$(propose_round "$snap" 2 4)")"
numbered=$(cat "$fx/drive-proposal.txt")
eq "approve a list" "merge-batch 41 42 45 46
dispatch 12	Add the exporter" "$(approved_goals "$numbered" '1, 4')"
eq "approve all" "7" "$(approved_goals "$numbered" 'all' | wc -l | tr -d ' ')"
eq "approve all but some" "merge-batch 41 42 45 46
dispatch 12	Add the exporter
fix-main 77
audit Open issues with no State label: #33
restart-queue" "$(approved_goals "$numbered" 'All but 2 3')"
eq "approve none" "" "$(approved_goals "$numbered" 'none')"
eq "a reply that names nothing approves nothing" "" "$(approved_goals "$numbered" 'looks good')"
eq "queue stale: old and unfinished" "yes" "$(queue_is_stale 1000000 1010000 'merging PR 41')"
eq "queue not stale: old but finished" "no" "$(queue_is_stale 1000000 1010000 'queue done')"
eq "queue not stale: recent" "no" "$(queue_is_stale 1000000 1003000 'merging PR 41')"
eq "queue not stale: no log" "no" "$(queue_is_stale '' 1000000 '')"
eq "wake: median plus a minute, less time spent" "460" "$(wake_after "$(printf '600\n700\n600\n')" 1000 1200)"
eq "wake: past the median floors at 60" "60" "$(wake_after "$(printf '600\n700\n600\n')" 1000 5000)"
eq "wake: no runs, nothing" "" "$(wake_after '' 1000 1200)"
eq "wake: no pending run, nothing" "" "$(wake_after "$(printf '600\n')" '' 1200)"
eq "wake: runs of other workflows are ignored" "600
700" "$(run_durations "$(printf 'completed\t0\t600\tci.yml\tpull_request\tb\ncompleted\t0\t5\tstate.yml\tpull_request\tb\ncompleted\t0\t900\tci.yml\tpush\tmain\ncompleted\t0\t700\tci.yml\tpull_request\tc\n')" ci.yml pull_request)"
eq "wake: capped at 1800" "1800" "$(wake_after "$(printf '3000\n3000\n')" 1000 1000)"
eq "owner decision found" "prices" "$(owner_decision_hit 'Set the Prices for the yearly plan' 'prices
policy')"
eq "owner decision absent" "" "$(owner_decision_hit 'Fix the date parser' 'prices
policy')"
eq "report trimmed per section" "Merged:
#1
#2
(and 1 more)
Blocked:
#9 on the owner" "$(trim_report 'Merged:
#1
#2
#3
Blocked:
#9 on the owner' 2)"

printf '\n# task_tier and agent_model_reason\n'
eq "Explore is a lookup" "lookup" "$(task_tier Explore 'Find config' 'Find where the port is set')"
eq "Plan is hard" "hard" "$(task_tier Plan 'Plan it' 'Plan the cache')"
eq "a short find is a lookup" "lookup" "$(task_tier general-purpose 'Find the parser' 'Find which file parses dates and report the path')"
eq "implement is hard" "hard" "$(task_tier general-purpose 'Add retries' 'Implement retries in the client')"
eq "a long find is routine" "routine" "$(task_tier general-purpose 'Survey' "$(awk 'BEGIN { for (i = 0; i < 130; i++) printf "find word "; }')")"
eq "a summary is routine" "routine" "$(task_tier general-purpose 'Summarize' 'Summarize the release notes in five lines')"
eq "no model on a lookup" "haiku lookup" "$(agent_model_reason Explore 'Find x' 'Find x' '')"
eq "no model on hard work" "opus hard" "$(agent_model_reason general-purpose 'Fix the bug' 'Debug the crash' '')"
eq "opus on a lookup is heavier than needed" "haiku lookup" "$(agent_model_reason Explore 'Find x' 'Find x' opus)"
eq "fable on routine work is heavier than needed" "sonnet routine" "$(agent_model_reason general-purpose 'Summarize' 'Summarize the notes' fable)"
eq "haiku on a lookup is fine" "" "$(agent_model_reason Explore 'Find x' 'Find x' haiku)"
eq "sonnet on routine is fine" "" "$(agent_model_reason general-purpose 'Summarize' 'Summarize the notes' sonnet)"
eq "a lighter model is always fine" "" "$(agent_model_reason general-purpose 'Fix it' 'Debug the crash' haiku)"
eq "opus on hard work is fine" "" "$(agent_model_reason Plan 'Plan it' 'Plan the cache' opus)"
eq "model ranks" "1 2 3 4 0" "$(printf '%s %s %s %s %s' "$(model_rank haiku)" "$(model_rank claude-sonnet-5-5)" "$(model_rank Opus)" "$(model_rank fable)" "$(model_rank '')")"

printf '\n# workflow_model_reason\n'
eq "every call has a model" "" "$(workflow_model_reason 'await agent("a", {model: "haiku"}); await agent("b", { model : "sonnet" })')"
eq "one call without a model" "1" "$(workflow_model_reason 'await agent("a", {model: "haiku"}); await agent("b", {label: "x"})')"
eq "no agents, nothing" "" "$(workflow_model_reason 'return 1')"

printf '\n# status page\n'
fixtures=$(mktemp -d)
mkdir -p "$fixtures/stubs"
printf 'name: Sign in\nstate: done\nissue: #3\nnote: Password and magic link.\n' > "$fixtures/stubs/sign-in.md"
printf 'name: Billing\nstate: blocked\nissue: #9\nnote: Waiting on the payment provider.\n' > "$fixtures/stubs/billing.md"
printf 'state: in progress\n' > "$fixtures/stubs/export.md"
printf '# comment\nDatabase: running\nMail: degraded\n' > "$fixtures/services.txt"
eq "stub_field reads a value" "Sign in" "$(stub_field "$fixtures/stubs/sign-in.md" name)"
eq "stub_field missing key prints nothing" "" "$(stub_field "$fixtures/stubs/sign-in.md" owner)"
page=$(render_status "$fixtures/stubs" "$fixtures/services.txt")
eq "one row per feature, sorted by file" "| Billing | blocked | #9 | Waiting on the payment provider. |
| export | in progress |  |  |
| Sign in | done | #3 | Password and magic link. |" "$(printf '%s\n' "$page" | grep '^| ' | grep -v -e 'Feature' -e 'Service' -e 'Database' -e 'Mail')"
eq "services table" "| Database | running |
| Mail | degraded |" "$(printf '%s\n' "$page" | grep -e '^| Database' -e '^| Mail')"
eq "not-done list leaves out done" "- Billing (blocked)
- export (in progress)" "$(printf '%s\n' "$page" | grep '^- ')"
eq "no services file, no services section" "" "$(render_status "$fixtures/stubs" "$fixtures/none.txt" | grep '^## Services')"
printf 'name: Only\nstate: done\n' > "$fixtures/stubs/billing.md"
printf 'name: Only\nstate: done\n' > "$fixtures/stubs/sign-in.md"
printf 'name: Only\nstate: done\n' > "$fixtures/stubs/export.md"
eq "all done says so" "Nothing. Every feature is done." "$(render_status "$fixtures/stubs" | tail -n 1)"

printf '\n# status check\n'
proj=$(mktemp -d)
cp -R "$root/templates/status" "$proj/status"
check=$(cd "$proj" && sh status/check.sh 2>&1; echo "exit $?")
eq "missing page fails" "STATUS.md is missing: run sh status/build.sh and commit the result.
exit 1" "$check"
(cd "$proj" && sh status/build.sh >/dev/null)
check=$(cd "$proj" && sh status/check.sh 2>&1; echo "exit $?")
eq "fresh page passes" "STATUS.md is current.
exit 0" "$check"
printf 'name: New\nstate: not started\n' > "$proj/status/stubs/new.md"
check=$(cd "$proj" && sh status/check.sh 2>&1; echo "exit $?")
eq "stale page fails" "STATUS.md is stale: run sh status/build.sh and commit the result.
exit 1" "$check"

printf '\n# classify_paths\n'
rules=$(cat "$root/templates/scripts/ci/classes.txt")
eq "app" "app" "$(classify_paths 'src/a.ts' "$rules")"
eq "deep path under src" "app" "$(classify_paths 'src/deep/er/a.ts' "$rules")"
eq "docs" "docs" "$(classify_paths 'README.md' "$rules")"
eq "a status stub is status, not docs" "status" "$(classify_paths 'status/stubs/a.md' "$rules")"
eq "workflow is ci" "ci" "$(classify_paths '.github/workflows/ci.yml' "$rules")"
eq "several classes, sorted, unique" "app docs tests" "$(classify_paths 'src/a.ts
docs/x.md
tests/a_test.py
src/b.ts' "$rules")"
eq "unknown path is other" "other" "$(classify_paths 'weird.bin' "$rules")"
eq "Windows separators are fine" "app" "$(classify_paths 'src\a.ts' "$rules")"
eq "empty input, no classes" "" "$(classify_paths '' "$rules")"

printf '\n# needs_rerun\n'
eq "no overlap merges" "no" "$(needs_rerun 'app' 'docs')"
eq "overlap reruns" "yes" "$(needs_rerun 'app tests' 'data app')"
eq "other on main reruns" "yes" "$(needs_rerun 'app' 'other')"
eq "other on the PR reruns" "yes" "$(needs_rerun 'other' 'docs')"
eq "ci on main reruns" "yes" "$(needs_rerun 'app' 'ci')"
eq "main unchanged merges" "no" "$(needs_rerun 'app' '')"
eq "an unclassified file on the PR merges when main has not moved" "no" "$(needs_rerun 'ci docs other' '')"
eq "blank main classes count as unmoved" "no" "$(needs_rerun 'other' ' ')"

printf '\n# state_label_from_body\n'
body="### State

waiting on owner

### Outcome

Something."
eq "reads the field" "state:waiting-on-owner" "$(state_label_from_body "$body")"
eq "ready" "state:ready" "$(state_label_from_body '### State
Ready')"
eq "after launch" "state:after-launch" "$(state_label_from_body '### State
After launch')"
eq "no field, no label" "" "$(state_label_from_body '### Outcome
x')"
eq "empty response, no label" "" "$(state_label_from_body '### State

_No response_')"
eq "CRLF body" "state:parked" "$(state_label_from_body "$(printf '### State\r\n\r\nparked\r\n')")"

printf '\n# spec_check_reason\n'
eq "a configured root counts as source" "missing" "$(spec_check_reason 'android/app/Main.kt' '' "$(printf 'src/\nandroid/')")"
eq "a root without its slash still counts" "missing" "$(spec_check_reason 'android/app/Main.kt' '' 'android')"
eq "outside every root is not source" "" "$(spec_check_reason 'docs/a.md' '' "$(printf 'src/\nandroid/')")"
eq "the default root is src" "missing" "$(spec_check_reason 'src/a.ts' '')"
eq "the queue names the build when the project has one" "1" "$(grep -c 'build \$d_build' "$root/templates/scripts/ci/merge-queue.sh")"
eq "both Deploy paths pass the build id" "2" "$(grep -c 'scripts/ci/build-id.sh HEAD' "$root/templates/.github/workflows/deploy.yml")"
eq "QUEUE.md no longer names --deploy as a flag to pass" "0" "$(grep -c '(`--deploy`, or\|`--deploy` starts' "$root/templates/scripts/ci/QUEUE.md")"
eq "the sync can stage without committing, and leaves project-owned files alone" "2" "$(grep -c 'no_commit=yes\|project-owned.txt; never compared' "$root/scripts/sync/sync-templates.sh")"

eq "src with its spec is fine" "" "$(spec_check_reason 'src/auth.ts
specs/sign-in/spec.md')"
eq "src without a spec is missing" "missing" "$(spec_check_reason 'src/auth.ts
README.md')"
eq "the constitution does not count" "missing" "$(spec_check_reason 'src/auth.ts
specs/constitution.md')"
eq "no src, nothing to check" "" "$(spec_check_reason 'docs/a.md
specs/constitution.md')"
eq "many spec folders warns" "many 2" "$(spec_check_reason 'src/a.ts
specs/sign-in/spec.md
specs/billing/spec.md')"
eq "src that names its spec in the body is fine" "" "$(spec_check_reason 'src/auth.ts' 'Adds the sign-in form.

Spec: specs/sign-in')"
eq "a spec path mentioned in the body counts" "" "$(spec_check_reason 'src/auth.ts' 'See specs/sign-in/spec.md for the flow.')"
eq "a body that names no spec is still missing" "missing" "$(spec_check_reason 'src/auth.ts' 'Adds the sign-in form. Closes #12')"
eq "the constitution named in the body does not count" "missing" "$(spec_check_reason 'src/auth.ts' 'per specs/constitution.md')"

printf '\n# rerun-free classes\n'
eq "the directive names the classes" "docs specs status" "$(rerun_free_classes "$rules")"
eq "no directive, nothing" "" "$(rerun_free_classes 'app src/*')"
eq "the directive is not a class" "app" "$(classify_paths 'src/a.ts' '!rerun-free docs
app src/*')"
eq "main moved only in a free class, no re-run" "no" "$(needs_rerun 'app specs' 'specs docs' 'docs specs status')"
eq "main moved in a free class and the app, re-run" "yes" "$(needs_rerun 'app specs' 'specs app' 'docs specs status')"
eq "ci on main still re-runs" "yes" "$(needs_rerun 'app' 'docs ci' 'docs specs status')"
eq "other on main still re-runs" "yes" "$(needs_rerun 'app' 'docs other' 'docs specs status')"
eq "a spec class" "specs" "$(classify_paths 'specs/sign-in/spec.md' "$rules")"

printf '\n# board mappings\n'
eq "label to state name" "Waiting on owner" "$(state_name_from_label state:waiting-on-owner)"
eq "a spaced label too" "Waiting on owner" "$(state_name_from_label 'state: waiting on owner')"
eq "a slug from either form" "in-progress in-progress" "$(state_slug state:in-progress) $(state_slug 'State: In Progress')"
eq "no slug from another label" "" "$(state_slug bug)"
eq "the form is read from the repository's labels" "spaced compact" "$(state_label_form "$(printf 'bug\nstate: ready\nstate: in progress\n')") $(state_label_form "$(printf 'bug\nstate:ready\n')")"
eq "a label in the spaced form" "state: waiting on owner" "$(state_label waiting-on-owner spaced)"
eq "and in the compact form by default" "state:waiting-on-owner" "$(state_label waiting-on-owner)"
eq "the body's state in the project's form" "state: after launch" "$(state_label_from_body '### State

After launch' spaced)"
eq "a state name in the project's form" "state: in progress" "$(label_from_state_name 'In progress' spaced)"
eq "all eight in the form" "8 8" "$(state_labels_all spaced | grep -c '^state: ') $(state_labels_all | grep -c '^state:[a-z]')"
eq "the labels JSON drops a spaced state label too" '{"labels":["bug","state: ready"]}' "$(state_labels_json "$(printf 'bug\nstate: in progress\n')" 'state: ready')"
eq "ready label" "Ready" "$(state_name_from_label state:ready)"
eq "not a state label" "" "$(state_name_from_label bug)"
eq "state name to label" "state:waiting-on-a-service" "$(label_from_state_name 'Waiting on a service')"
eq "round trip" "After launch" "$(state_name_from_label "$(label_from_state_name 'After launch')")"
eq "first state label in a list" "state:parked" "$(state_label_in 'bug, state:parked,task')"
eq "no state label in a list" "" "$(state_label_in 'bug,task')"
eq "status for in progress" "In Progress" "$(status_for 'In progress' false)"
eq "status for ready" "Todo" "$(status_for Ready false)"
eq "status for parked" "Todo" "$(status_for Parked false)"
eq "status for a closed issue is Done whatever the state" "Done" "$(status_for 'In progress' true)"
printf '\n# workflow_breaks\n'
wb_changes=$(printf '.github/workflows/audit.yml\t1000\t2026-10-15\tSync templates to plugin 0.22.1\n.github/workflows/board-sync.yml\t1000\t2026-10-15\tSync templates to plugin 0.22.1\n.github/workflows/ci.yml\t500\t2026-10-10\tci\n')
wb_runs=$(printf '.github/workflows/audit.yml\tfailure\t3000\n.github/workflows/audit.yml\tfailure\t2000\n.github/workflows/audit.yml\tsuccess\t900\n.github/workflows/board-sync.yml\tfailure\t2000\n.github/workflows/board-sync.yml\tsuccess\t1500\n.github/workflows/board-sync.yml\tsuccess\t900\n.github/workflows/ci.yml\tfailure\t600\n.github/workflows/ci.yml\tfailure\t400\n')
eq "a workflow that passed before its change and failed every run since is named" "audit.yml has failed every run (2) since it was changed on 2026-10-15 (Sync templates to plugin 0.22.1)" "$(workflow_breaks "$wb_runs" "$wb_changes")"
eq "one that failed before too is not" "" "$(workflow_breaks "$(printf '.github/workflows/ci.yml\tfailure\t600\n.github/workflows/ci.yml\tfailure\t400\n')" "$wb_changes")"
eq "nor one with no run since" "" "$(workflow_breaks "$(printf '.github/workflows/audit.yml\tsuccess\t900\n')" "$wb_changes")"
eq "nor one with a pass since" "" "$(workflow_breaks "$(printf '.github/workflows/audit.yml\tsuccess\t3000\n.github/workflows/audit.yml\tfailure\t2000\n.github/workflows/audit.yml\tsuccess\t900\n')" "$wb_changes")"
eq "a cancelled run since is not a failure" "" "$(workflow_breaks "$(printf '.github/workflows/audit.yml\tcancelled\t2000\n.github/workflows/audit.yml\tsuccess\t900\n')" "$wb_changes")"
eq "the brief and the audit both run workflow-breaks.sh" "1 1" "$(grep -c 'sh scripts/ci/workflow-breaks.sh' "$root/hooks/scripts/session-brief.sh") $(grep -c 'sh scripts/ci/workflow-breaks.sh' "$root/templates/.github/workflows/audit.yml")"
printf '\n# drain_late\n'
eq "a drain last run 6 h ago on a 2 h schedule is late" "Queue drain: last ran 6 h ago, scheduled every 2 h; GitHub is firing it late. A green pull request waits until then or until a session runs sh scripts/ci/merge-queue.sh --drain." "$(drain_late 1000 $((1000 + 21600)) 2)"
eq "one 3 h ago is not" "" "$(drain_late 1000 $((1000 + 10800)) 2)"
eq "exactly twice the interval is not" "" "$(drain_late 1000 $((1000 + 14400)) 2)"
eq "no last run says nothing" "" "$(drain_late "" 99999 2)"
eq "the brief and the audit both run drain-late.sh" "1 1" "$(grep -c 'sh scripts/ci/drain-late.sh' "$root/hooks/scripts/session-brief.sh") $(grep -c 'sh scripts/ci/drain-late.sh' "$root/templates/.github/workflows/audit.yml")"

printf '\n# audit helpers\n'
eq "issues without a state label" "12
15" "$(issues_without_state '12 bug,task
14 state:ready,task
15
16 task,state:parked')"
eq "issue refs, unique, in order" "4
12" "$(issue_refs 'Closes #4 and fixes #12; see #4 again')"
eq "no refs, nothing" "" "$(issue_refs 'no numbers here')"
eq "clean audit says nothing" "" "$(audit_comment '' '')"
eq "missing only" "Open issues with no State label:
- #12
- #15" "$(audit_comment '12
15' '')"
eq "stale only" "Issues still open and labeled ready after their PR merged:
- #4 (merged in #30)" "$(audit_comment '' '30 4')"
eq "both, with a blank line between" "Open issues with no State label:
- #12

Issues still open and labeled ready after their PR merged:
- #4 (merged in #30)" "$(audit_comment '12' '30 4')"
eq "red main comes first" "Main is red and the issue is still open:
- #77

Open issues with no State label:
- #12" "$(audit_comment '12' '' '77')"
eq "red only" "Main is red and the issue is still open:
- #77" "$(audit_comment '' '' '77')"

printf '\n# setup_check_reason and has_crlf\n'
setup_pats=$(cat "$root/templates/scripts/ci/setup-paths.txt")
eq "migration without SETUP.md" "migrations/0002_x.sql" "$(setup_check_reason 'src/a.ts
migrations/0002_x.sql' "$setup_pats")"
eq "migration with SETUP.md is fine" "" "$(setup_check_reason 'migrations/0002_x.sql
SETUP.md' "$setup_pats")"
eq "no setup file, nothing to check" "" "$(setup_check_reason 'src/a.ts
docs/b.md' "$setup_pats")"
eq "a workflow change is not a setup step" "" "$(setup_check_reason '.github/workflows/ci.yml' "$setup_pats")"
eq "a dependency bump is not a setup step" "" "$(setup_check_reason 'package.json' "$setup_pats")"
eq "a migration is a setup step" "migrations/002_x.sql" "$(setup_check_reason 'migrations/002_x.sql' "$setup_pats")"
own_pats="manual docs/setup.md
$setup_pats"
eq "the manual defaults to SETUP.md" "SETUP.md" "$(setup_manual "$setup_pats")"
eq "a manual line names the project's own" "docs/setup.md" "$(setup_manual "$own_pats")"
eq "the project's own manual satisfies the check" "" "$(setup_check_reason 'migrations/0002_x.sql
docs/setup.md' "$own_pats")"
eq "SETUP.md no longer counts when the manual is elsewhere" "migrations/0002_x.sql" "$(setup_check_reason 'migrations/0002_x.sql
SETUP.md' "$own_pats")"
eq "crlf found" "yes" "$(has_crlf "$(printf 'a\r\nb')")"
eq "lf only" "" "$(has_crlf "$(printf 'a\nb')")"

printf '\n# quoted text is text, and nothing waits on input\n'
eq "a multi-line --body with quotes keeps the label after it" "" "$(state_label_reason 'gh issue create --title "Fix chimes" --body "First line.
The setting says "off" here.
Last line." --label state:in-progress')"
eq "a body holding && ; | and ( ) keeps the label after it" "" "$(state_label_reason 'gh issue create --title t --body "Run a && b; then c | d (mostly)." --label state:ready')"
eq "a single-quoted multi-line body keeps the label after it" "" "$(state_label_reason "gh issue create --title t --body 'One.
Two.' --label \"state: in progress\"")"
eq "a multi-line body with no label is still refused" "gh issue create" "$(state_label_reason 'gh issue create --title t --body "One.
Two."')"
eq "an rm inside a quoted substitution is still seen" "rm" "$(delete_reason 'echo "$(rm -rf build)"')"
eq "an rm inside plain quotes is text" "" "$(delete_reason 'git commit -m "rm the old files; && done"')"
eq "a bare cat writing to /dev/null waits forever" "cat >> /dev/null" "$(stdin_wait_reason 'cat >> /dev/null')"
eq "a bare cat waits" "cat" "$(stdin_wait_reason 'cd x && cat')"
eq "read with nothing to read waits" "read answer" "$(stdin_wait_reason 'read answer')"
eq "head with no file waits" "head -5" "$(stdin_wait_reason 'head -5')"
eq "cat of a file is fine" "" "$(stdin_wait_reason 'cat a.txt >> b.txt')"
eq "cat fed by a pipe is fine" "" "$(stdin_wait_reason 'git log | cat')"
eq "cat fed by a redirect is fine" "" "$(stdin_wait_reason 'cat < in.txt')"
eq "cat fed by a heredoc is fine" "" "$(stdin_wait_reason 'cat > f.txt <<EOF
body
EOF')"
eq "tee at the end of a pipe is fine" "" "$(stdin_wait_reason 'make | tee out.log')"
eq "the word cat in a string is fine" "" "$(stdin_wait_reason 'echo "cat" && ls')"
eq "a cd chained to a commit waits for nothing" "" "$(stdin_wait_reason 'cd ../wt && git commit -m hi')"
eq "a short heredoc into a commit is fine" "" "$(stdin_wait_reason 'git -C ../wt commit -F - <<EOF
one line
EOF')"
eq "a heredoc inside a substitution is fine" "" "$(stdin_wait_reason 'gh pr create --body "$(cat <<EOF
body
EOF
)"')"

printf '\n# merging only through the queue\n'
eq "a direct merge" "gh pr merge" "$(direct_merge_reason 'gh pr merge 41 --squash')"
eq "a direct merge after cd" "gh pr merge" "$(direct_merge_reason 'cd ../wt && gh pr merge 41 --merge --delete-branch')"
eq "turning auto-merge off is allowed" "" "$(direct_merge_reason 'gh pr merge 41 --disable-auto')"
eq "the queue itself is not a direct merge" "" "$(direct_merge_reason 'sh scripts/ci/merge-queue.sh --serial 41')"
eq "viewing a pull request is not a merge" "" "$(direct_merge_reason 'gh pr view 41')"
eq "a drain names its mode" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --drain')"
eq "a drain with more than two numbers is still named" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --drain 1 2 3')"

printf '\n# drain\n'
. "$root/templates/scripts/ci/batch-lib.sh"
open='41	false	MERGEABLE	green	main
42	false	MERGEABLE	pending	main
43	true	MERGEABLE	green	main
44	false	CONFLICTING	green	main
45	false	MERGEABLE	green	release
46	false	UNKNOWN	green	main
47	false	MERGEABLE	red	main
48	false	MERGEABLE	pending	main'
eq "green, not draft, not conflicting, aimed at main" "41
46" "$(drain_candidates "$open" main)"
eq "a pull request already tried is not picked again" "46" "$(drain_candidates "$open" main '41')"
eq "running ones are counted, drafts and other bases are not" "2" "$(drain_waiting "$open" main)"
eq "nothing open, nothing picked" "" "$(drain_candidates '' main)"
eq "red pull requests get one retry" "47" "$(drain_retry "$open" main '')"
eq "a red pull request already retried is not retried again" "" "$(drain_retry "$open" main '47')"
eq "a conflict needs attention at once" "44	has conflicts with main" "$(drain_attention "$open" main '')"
eq "red again after its retry needs attention" "44	has conflicts with main
47	failed CI twice" "$(drain_attention "$open" main '47')"
eq "drafts and other bases never need attention here" "" "$(drain_attention "43	true	CONFLICTING	red	main
45	false	CONFLICTING	red	release" main '43 45')"

eq "one green with others running: hold" "yes" "$(drain_hold 1 3)"
eq "two green: batch now, never one then the other" "no" "$(drain_hold 2 1)"
eq "three green: batch now" "no" "$(drain_hold 3 4)"
eq "nothing running: merge" "no" "$(drain_hold 1 0)"
eq "nothing green: nothing to hold" "no" "$(drain_hold 0 2)"

printf '\n# check-runs and mergeable_state through REST\n'
eq "no check runs is none" "none" "$(rest_rollup '')"
eq "all success is green" "green" "$(rest_rollup 'success
skipped
neutral')"
eq "one failure is red" "red" "$(rest_rollup 'success
failure')"
eq "a run still going is pending" "pending" "$(rest_rollup 'success
in_progress')"
eq "red beats pending" "red" "$(rest_rollup 'queued
timed_out')"
eq "a cancelled job is not red" "cancelled" "$(rest_rollup 'success
cancelled')"
eq "a failure beside a cancel is red" "red" "$(rest_rollup 'cancelled
failure')"
eq "a cancel still running is pending" "pending" "$(rest_rollup 'cancelled
in_progress')"
eq "a cancelled pull request is re-run" "51" "$(drain_retry "51	false	MERGEABLE	cancelled	main" main '')"
eq "and re-run again the next round: cancelled is waiting, not failing" "51" "$(drain_retry "51	false	MERGEABLE	cancelled	main" main '51')"
eq "a cancelled pull request counts as waiting" "1" "$(drain_waiting "51	false	MERGEABLE	cancelled	main" main '51')"
eq "a cancelled pull request is never set aside" "" "$(drain_attention "51	false	MERGEABLE	cancelled	main" main '51')"
eq "the required check passed on the commit" "passed" "$(required_check "$(printf 'classify\tcompleted\tsuccess\nCI passed\tcompleted\tsuccess')")"
eq "a green run without the required check is not ready" "missing" "$(required_check "$(printf 'classify\tcompleted\tsuccess\napp\tcompleted\tsuccess')")"
eq "the required check still running" "pending" "$(required_check "$(printf 'CI passed\tin_progress\t')")"
eq "the required check failed" "failed" "$(required_check "$(printf 'CI passed\tcompleted\tfailure')")"
eq "a project's own required check" "passed" "$(required_check "$(printf 'all green\tcompleted\tsuccess')" 'all green')"
eq "the summary failing on a cancelled job is not red" "cancelled" "$(rest_rollup_named "$(printf 'app\tcancelled\nclassify\tsuccess\nCI passed\tfailure')")"
eq "a real failure beside a cancel is red" "red" "$(rest_rollup_named "$(printf 'app\tcancelled\ntests\tfailure\nCI passed\tfailure')")"
eq "the summary failing alone is red" "red" "$(rest_rollup_named "$(printf 'app\tsuccess\nCI passed\tfailure')")"
eq "a project's own summary name" "cancelled" "$(rest_rollup_named "$(printf 'web\tcancelled\nall green\tfailure')" 'all green')"
eq "an issue a member closes is carried" "Closes #64" "$(carried_refs 'An emote per title.

Closes #64')"
eq "fixes and resolves are carried as closes, once each" "Closes #12
Closes #13" "$(carried_refs 'Fixes #12, resolves #13 and closes #12')"
eq "a member's spec is carried" "Spec: specs/004-dashboard" "$(carried_refs 'Spec: specs/004-dashboard')"
eq "a member's escape lines ride along whole" "Spec: specs/004-dashboard
Parity: copy only, no logic change
Twin: web/src/a.ts mirrors app/src/a.ts" "$(carried_refs 'Spec: specs/004-dashboard
  Parity: copy only, no logic change
Twin: web/src/a.ts mirrors app/src/a.ts')"
eq "a project names its own escape keys" "Waiver: perf budget" "$(QUEUE_CARRY_KEYS='Waiver' carried_refs 'Waiver: perf budget
Parity: not carried here')"
eq "a batch body starts with the queue's marker" "<!-- merge-queue:batch -->" "$(batch_pr_body "$(printf '41\tA\n')" | head -n 1)"
eq "a batch is known by its marker" "yes" "$(is_batch_body "$(batch_pr_body "$(printf '41\tA\n')")")"
eq "and by the sentence older batches had" "yes" "$(is_batch_body 'One integration run for the pull requests below, merged in this order')"
eq "a branch named batch-something is not a batch" "" "$(is_batch_body 'Carry escape lines into batch bodies. Closes #483')"
eq "the queue finds batches by body, not branch" "0 2" "$(grep -c 'startswith("batch-")' "$root/templates/scripts/ci/merge-queue.sh") $(grep -c 'contains("<!-- merge-queue:batch -->")' "$root/templates/scripts/ci/merge-queue.sh")"
eq "each run's batch branch is its own" "batch-2026-10-15-041200" "$(batch_branch_name 2026-10-15 1 041200)"
eq "and the second that minute" "batch-2026-10-15-041200-2" "$(batch_branch_name 2026-10-15 2 041200)"
eq "a hold label holds" "held by its label" "$(held_reason "$(printf 'bug\nqueue:hold')" '')"
eq "so does the short label" "held by its label" "$(held_reason 'Hold' '')"
eq "and a Queue: hold line" 'held by its "Queue: hold" line' "$(held_reason '' "$(printf 'Fix the chime.\n  Queue: hold until #301 lands')")"
eq "a body that only mentions holding is not held" "" "$(held_reason 'bug' 'We should hold off on the cache.')"
eq "pause for two hours" "7200" "$(( $(pause_until 0 2h) ))"
eq "pause for 45 minutes" "2700" "$(pause_until 0 45m)"
eq "bare minutes" "5400" "$(pause_until 0 90)"
eq "a length it cannot read pauses nothing" "" "$(pause_until 0 soon)"
eq "the drain, a batch and --serial all honour a hold" "3" "$(grep -c 'held_reason\|pr_held "\$pr"' "$root/templates/scripts/ci/merge-queue.sh" | awk '{print ($1 >= 3) ? 3 : $1}')"
eq "the scheduled drain skips while paused or a session drains" "1" "$(grep -c 'vars.QUEUE_PAUSED_UNTIL }}" "\${{ vars.QUEUE_LOCAL_DRAIN_UNTIL' "$root/templates/.github/workflows/queue-drain.yml")"
eq "a release on workflow_run of CI is per merge" "yes" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n    branches: [main]\n')")"
eq "quoted CI too" "yes" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'on:\n  workflow_run:\n    workflows: [\"CI\"]\n')")"
eq "a release that follows Deploy is not" "" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'on:\n  workflow_run:\n    workflows: [Deploy]\n  workflow_dispatch:\n')")"
eq "nor a workflow named CI elsewhere" "" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'name: CI\non:\n  push:\n')")"
eq "the release workflows in deploy.json" "play-internal.yml
app-distribution.yml" "$(release_workflows '{"path": "guard", "releases": ["play-internal.yml", "app-distribution.yml"]}')"
eq "none listed, none started" "" "$(release_workflows '{"path": "guard"}')"
eq "the queue starts the listed releases when no Deploy run will" "1" "$(grep -c 'Started the release workflow' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the drain never runs hosted by default" "0" "$(grep -v '^#' "$root/templates/.github/workflows/queue-drain.yml" | grep -c 'ubuntu-latest')"
eq "its runs-on falls back to self-hosted" "1" "$(grep -c "runs-on: \${{ vars.QUEUE_RUNS_ON || 'self-hosted' }}" "$root/templates/.github/workflows/queue-drain.yml")"
eq "and with QUEUE_RUNS_ON unset the Windows job runs on a self-hosted Windows runner" "2" "$(grep -c "vars.QUEUE_RUNS_ON == '' || contains(vars.QUEUE_RUNS_ON, 'windows')\|runs-on: \${{ vars.QUEUE_RUNS_ON || 'windows' }}" "$root/templates/.github/workflows/queue-drain.yml")"
eq "the other drain job runs only for a label not naming Windows" "1" "$(grep -c "if: \${{ vars.QUEUE_RUNS_ON != '' && !contains(vars.QUEUE_RUNS_ON, 'windows') }}" "$root/templates/.github/workflows/queue-drain.yml")"
eq "and skips itself after a recent drain, or while paused" "2" "$(grep -c 'skipping this one' "$root/templates/.github/workflows/queue-drain.yml")"
eq "the batch checkout links packages only when the lockfiles match" "1" "$(grep -c 'if \[ "\$em_lock" = "\$em_main" \] && \[ -d "\$main_dir/\$d/node_modules" \]' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a stale link is removed, never the packages behind it" "1" "$(grep -c 'cmd //c rmdir' "$root/templates/scripts/ci/merge-queue.sh")"
eq "file: dependencies by path" "packages/core
../shared" "$(file_deps '{"dependencies": {"@app/core": "file:packages/core", "react": "^18"}, "devDependencies": {"@app/shared": "file:../shared"}}')"
eq "no file: dependency, nothing" "" "$(file_deps '{"dependencies": {"react": "^18"}}')"
eq "the file: trees are part of the install hash and a stale install is named, not main" "2 1" "$(grep -c 'pkg_hash "\$' "$root/templates/scripts/ci/merge-queue.sh") $(grep -c "installed packages are older than origin" "$root/templates/scripts/ci/merge-queue.sh")"
eq "a member that changes dependencies is installed for" "1" "$(grep -c 'package.json"\*) ensure_modules' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the project's install command can be named" "1" "$(grep -c 'QUEUE_INSTALL_COMMAND:-npm ci' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a lagging pull ref falls back to the branch" "1" "$(grep -c 'fetch -q origin "+refs/heads/$fph_branch:refs/queue/pr-$1"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "and is said as lagging, never 'try again'" "0" "$(grep -c 'try again' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the gate and the batch use the same fetch" "3" "$(grep -c 'fetch_pr_head "' "$root/templates/scripts/ci/merge-queue.sh")"
# A loop whose last command is "[ test ] && cmd" returns 1 when the test is
# false; inside $(...) under set -e that ends the script without a word.
# It did, three times (worktrees.sh close, --serial, the hold scan).
tail_tests=$(cd "$root" && for f in $(git ls-files '*.sh'); do
  awk -v f="$f" '{ l[NR] = $0 } END { for (i = 1; i <= NR; i++) { if (l[i] !~ /\][ \t]*&&/ || l[i] ~ /\|\|/) continue; j = i + 1; while (j <= NR && l[j] ~ /^[ \t]*(#.*)?$/) j++; if (j <= NR && l[j] ~ /^[ \t]*done/) printf "%s:%d\n", f, i } }' "$f"
done)
eq "no loop in any script ends on a bare test" "" "$tail_tests"
# The same on one line: "do [ test ] && cmd; done". The settle loop after a
# merged batch ended the next round that way (its members read as closed,
# not merged, for a moment).
oneline_tests=$(cd "$root" && grep -rnE 'do .*\] *&& [^|]*; *done' --include='*.sh' templates hooks scripts status 2>/dev/null | grep -v '||' | cut -d: -f1,2)
eq "nor any one-line loop" "" "$oneline_tests"
eq "the queue never stops without a word, on screen and in its log" "2" "$(grep -c 'stopped (exit \$qe_rc) during: \$queue_step' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the hold scan ends on an if" "1" "$(grep -c 'if \[ -n "\$h_why" \]; then printf' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the queue deploys from state after a serial, a batch and a drain, never from a flag" "3 0" "$(grep -c 'deploy_if_due "\$' "$root/templates/scripts/ci/merge-queue.sh") $(grep -c 'then_deploy' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the plugin's own scripts never ship" "no no no yes" "$(. "$root/templates/scripts/ci/deploy-lib.sh"; for p in scripts/ci/merge-queue.sh scripts/design/generate.mjs scripts/pr-open.sh scripts/core/pack.sh; do ships_path "$p" .; done | tr '\n' ' ' | sed 's/ $//')"
eq "a scripts-only landing deploys nothing" "skip" "$(. "$root/templates/scripts/ci/deploy-lib.sh"; deploy_skip "$(printf 'scripts/ci/merge-queue.sh\n.github/workflows/ci.yml\n.claude/deploy.json\nSETUP.md')" .)"
eq "one shipping path among them deploys" "build" "$(. "$root/templates/scripts/ci/deploy-lib.sh"; deploy_skip "$(printf 'scripts/ci/merge-queue.sh\nsrc/app/page.tsx')" .)"
eq "the queue asks what ships before starting Deploy" "1 1" "$(grep -c 'deploy-gate.sh" --ships' "$root/templates/scripts/ci/merge-queue.sh") $(grep -c 'deploy: skipped, nothing that ships changed' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the drain's deploy function is defined before the drain calls it" "yes" "$(awk '/^deploy_if_due\(\) \{/ && !d { d = NR } /^  deploy_if_due "\$d_begin"/ && !c { c = NR } END { print (d && c && d < c) ? "yes" : "no" }' "$root/templates/scripts/ci/merge-queue.sh")"
eq "releaseOn ask" "ask" "$(release_on '{"releases": ["a.yml"], "releaseOn": "ask"}')"
eq "releaseOn defaults to deploy" "deploy" "$(release_on '{"releases": ["a.yml"]}')"
eq "a turned-off release is held" "(it is turned off; a turned-off release is held on purpose)" "$(release_hold disabled_manually deploy landing)"
eq "an ask release is held after a landing" "(releaseOn is ask; merge-queue.sh --release starts it)" "$(release_hold active ask landing)"
eq "an ask release starts when asked" "" "$(release_hold active ask ask)"
eq "a deploy release starts after a landing" "" "$(release_hold active deploy landing)"
eq "a turned-off release is held even when asked" "(it is turned off; a turned-off release is held on purpose)" "$(release_hold disabled_manually ask ask)"
eq "the PowerShell step names its own policy, in the step and in the header" "2 0" "$(grep -c "shell: powershell -NoProfile -ExecutionPolicy Bypass -Command \". '{0}'\"" "$root/templates/.github/workflows/runner-check.yml") $(grep -c '^        shell: powershell$' "$root/templates/.github/workflows/runner-check.yml")"
gp=$(mktemp -d)
(
  cd "$gp" && mkdir -p design scripts/design && cp "$root/templates/scripts/design/generate.mjs" scripts/design/
  printf '{"outputs": {"ts": "web/src/design/tokens.ts", "css": null, "kotlin": null, "swift": null}, "type": {"families": [], "roles": []}}\n' > design/tokens.json
  printf '{"icons": []}\n' > design/icons.json
  node scripts/design/generate.mjs --check >/dev/null 2>&1; echo "missing folder $?"
  printf '{"outputs": {"ts": null, "css": null, "kotlin": null, "swift": null}, "type": {"families": [], "roles": []}}\n' > design/tokens.json
  node scripts/design/generate.mjs --check >/dev/null 2>&1; echo "no outputs $?"
) > "$gp.out" 2>&1
eq "the design check passes an output whose folder does not exist yet" "missing folder 0" "$(sed -n 1p "$gp.out")"
eq "and a project with no outputs yet" "no outputs 0" "$(sed -n 2p "$gp.out")"
eq "a green pull request holds the deploy" "2 green PRs waiting" "$(deploy_gate 2 1000 5000 60)"
eq "one green pull request, singular" "1 green PR waiting" "$(deploy_gate 1 '' 5000 60)"
eq "inside the interval holds it" "last deploy 35 minutes ago, interval 60" "$(deploy_gate 0 2900 5000 60)"
eq "past the interval, due" "" "$(deploy_gate 0 1000 5000 60)"
eq "no deploy recorded, due" "" "$(deploy_gate 0 '' 5000 60)"
eq "the state line when held by a pull request" "deploy: held, 2 green PRs waiting; last deploy 66 min ago" "$(deploy_state 2 1000 5000 60)"
eq "the state line when held by the interval" "deploy: held, last deploy 35 minutes ago, interval 60" "$(deploy_state 0 2900 5000 60)"
eq "the state line when due" "deploy: due; last deploy 66 min ago (interval 60)" "$(deploy_state 0 1000 5000 60)"
eq "no held line when nothing is held" "" "$(held_note 0)"
eq "a held green pull request is said, singular" "deploy: 1 green PR on hold, not waited for" "$(held_note 1)"
eq "and plural" "deploy: 2 green PRs on hold, not waited for" "$(held_note 2)"
eq "the gate skips held pull requests the way the drain does" "1" "$(grep -c 'held_reason' "$root/templates/scripts/ci/deploy-gate.sh" | awk '{print ($1 >= 1) ? 1 : 0}')"
gh_stub_d=$(mktemp -d); mkdir -p "$gh_stub_d/.claude"
printf '{ "intervalMinutes": 0 }\n' > "$gh_stub_d/.claude/deploy.json"
cat > "$gh_stub_d/gh" <<'GHEOF'
#!/bin/sh
case "$2" in
  *pulls*) printf 'abc123	-	%s\n' 'Fix. | Queue: hold | waiting on an owner step' ;;
  *check-runs*) echo green ;;
esac
GHEOF
gate_out=$(cd "$gh_stub_d" && PATH="$gh_stub_d:$PATH" sh "$root/templates/scripts/ci/deploy-gate.sh" 2>&1 | head -1)
eq "a held pull request with no labels is not waited for" "deploy: due" "$(printf '%s' "$gate_out" | cut -c1-11)"
eq "the gate writes an empty labels column as a dash" "1" "$(grep -c 'if . == "" then "-"' "$root/templates/scripts/ci/deploy-gate.sh")"
eq "the state line with no deploy yet" "deploy: due; none recorded (interval 60)" "$(deploy_state 0 '' 5000 60)"
eq "a run that is re-running is pending, whatever its old checks say" "1" "$(grep -c 'its run is \$run_status (a new attempt)' "$root/templates/scripts/ci/merge-queue.sh")"
eq "--serial by hand waits for checks already running" "1" "$(grep -c 'its checks are still running; waiting for them' "$root/templates/scripts/ci/merge-queue.sh")"
eq "and for a pending required check" "1" "$(grep -c 'is still running; waiting for it, then merging' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a drain never waits on one pull request" "2" "$(grep -c '\[ -z "\$QUEUE_IN_DRAIN" \] && \[ -z "\${serial_waited:-}" \]' "$root/templates/scripts/ci/merge-queue.sh")"
eq "--serial waits once for the run its refresh started" "1" "$(grep -c 'serial_refreshed=1' "$root/templates/scripts/ci/merge-queue.sh")"
eq "an unknown mergeable state is read again" "1" "$(grep -c 'while \[ "\$o_mw" = UNKNOWN \]' "$root/templates/scripts/ci/merge-queue.sh")"
eq "CI may read pull requests" "1" "$(grep -c '^  pull-requests: read' "$root/templates/.github/workflows/ci.yml")"
ci_job() { awk -v j="  $1:" '$0 == j {f=1; next} /^  [a-z-]*:$/ {f=0} f' "$root/templates/.github/workflows/ci.yml"; }
ci_stops() { ci_job "$1" | grep -c -e '^      actions: write$' -e "if: failure() && github.event_name == 'pull_request'" -e 'gh run cancel \${{ github.run_id }}'; }
eq "a failed pull-request job stops the rest of its run" "3 3 3" "$(ci_stops checks) $(ci_stops app) $(ci_stops screens)"
eq "the full run on main is never stopped" "0" "$(ci_stops full)"
eq "the spec, design and mock checks read the live body" "3" "$(grep -c 'SPEC_TEXT=$(gh api' "$root/templates/.github/workflows/ci.yml")"
eq "a body with neither carries nothing" "" "$(carried_refs 'Just a copy fix.')"
eq "the batch body carries its members' lines" "Carried from the members:

Closes #64
Spec: specs/004-dashboard" "$(batch_pr_body "$(printf '79\tAn emote\n')" 'Closes #64
Spec: specs/004-dashboard
Closes #64' | tail -n 4)"
eq "the runner-path build keeps its own variable, never a placeholder" "0" "$(awk '/^  build-on-runner:$/{j=1;next} /^  [a-z-]*:$/{j=0} j' "$root/templates/.github/workflows/deploy.yml" | grep -cwE 'RUNS_ON|RUN_SHELL')"
eq "the Deploy workflow does not need jq" "0" "$(grep -c 'jq -r\| jq ' "$root/templates/.github/workflows/deploy.yml")"
eq "the queue never reads FETCH_HEAD" "0" "$(grep -c 'rev-parse FETCH_HEAD' "$root/templates/scripts/ci/merge-queue.sh")"
eq "dirty is conflicting" "CONFLICTING" "$(mergeable_word dirty)"
eq "clean is mergeable" "MERGEABLE" "$(mergeable_word clean)"
eq "behind is still mergeable" "MERGEABLE" "$(mergeable_word behind)"
eq "unknown is unknown" "UNKNOWN" "$(mergeable_word unknown)"
eq "empty is unknown" "UNKNOWN" "$(mergeable_word '')"

printf '\n# board calls refused for a rate limit\n'
eq "gh's unknown owner type is a refusal" "yes" "$(board_refusal 'unknown owner type: someone')"
eq "a rate limit message is a refusal" "yes" "$(board_refusal 'GraphQL: API rate limit exceeded for user ID 1')"
eq "a secondary limit is a refusal" "yes" "$(board_refusal 'You have exceeded a secondary rate limit')"
eq "a missing field is not" "no" "$(board_refusal 'Project 3 has no State field')"
eq "empty output is not" "no" "$(board_refusal '')"

printf '\n# pull request bodies, stray closing keywords\n'
. "$root/templates/scripts/pr-lib.sh"
eq "a deliberate Closes line passes" "" "$(pr_stray_closers 'Closes #115
Spec: specs/x

Files #105 and see #106.')"
eq "Closes with a colon on a line start is refused" "Closes: #7" "$(pr_stray_closers 'Closes: #7')"
eq "fixed with a colon mid-sentence is refused" "filed rather than fixed: #105" "$(pr_stray_closers 'Closes #1
filed rather than fixed: #105')"
eq "fix family is refused" "Fixes #3" "$(pr_stray_closers 'Fixes #3')"
eq "resolve family, any case, is refused" "This RESOLVES #4 too" "$(pr_stray_closers 'This RESOLVES #4 too')"
eq "close family is refused" "we closed #5" "$(pr_stray_closers 'we closed #5')"
eq "owner/repo form is refused" "resolved Pawper/other#9" "$(pr_stray_closers 'resolved Pawper/other#9')"
eq "a second keyword on the deliberate line is refused" "Closes #1, fixes #2" "$(pr_stray_closers 'Closes #1, fixes #2')"
eq "a keyword inside a word is not one" "" "$(pr_stray_closers 'the prefix #4 and disclosed #5')"

printf '\n# decisions, one file each\n'
. "$root/templates/scripts/decisions-lib.sh"
eq "table rows become number, date and text" "123	2026-10-13	Voice long lines in chunks.
124	2026-10-13	No affirmation in the meditation." "$(decision_rows '| Decision | Date | What |
|---|---|---|
| D123 | 2026-10-13 | Voice long lines in chunks. |
| D124 | 2026-10-13 | No affirmation in the meditation. |')"
eq "a row without a date" "7		Sign-in is by email link." "$(decision_rows '| D7 | Sign-in is by email link. |')"
eq "a slug from the first words" "voice-long-lines-in-sentence-chunks" "$(decision_slug 'Voice long lines in sentence chunks of about 40 tokens.')"
eq "four-digit names" "0124-no-affirmation.md" "$(decision_name 124 no-affirmation)"
eq "the table is in number order, whatever the file order" "| Decision | Date | What was decided |
|---|---|---|
| D123 | 2026-10-13 | Voice long lines in chunks. |
| D124 | 2026-10-13 | No affirmation in the meditation. |" "$(decision_table "$(decision_file 124 2026-10-13 'No affirmation in the meditation.')
@@@
$(decision_file 123 2026-10-13 'Voice long lines in chunks.')
@@@")"
dd=$(mktemp -d)
(
  cd "$dd" && mkdir -p docs .claude scripts && cp "$root/templates/scripts/decisions.sh" "$root/templates/scripts/decisions-lib.sh" scripts/
  printf '# Brief\n\nIntro.\n\n## Decisions\n\n| Decision | Date | What |\n|---|---|---|\n| D1 | 2026-10-01 | First thing. |\n| D2 | 2026-10-02 | Second thing. |\n\n## After\n\nMore.\n' > docs/product-brief.md
  printf 'migration supabase/migrations/*.sql\ndecision docs/product-brief.md D\n' > .claude/numbering.txt
  sh scripts/decisions.sh split >/dev/null
  ls docs/decisions | tr '\n' ' '; echo
  grep -c '^| D' docs/product-brief.md
  grep -c 'scripts/decisions.sh new' docs/product-brief.md
  grep -c '^## After' docs/product-brief.md
  grep '^decision' .claude/numbering.txt
  sh scripts/decisions.sh list | tail -n 1
) > "$dd.out" 2>&1
eq "split writes one file per decision" "0001-first-thing.md 0002-second-thing.md " "$(sed -n 1p "$dd.out")"
eq "split leaves no decision row in the brief" "0" "$(sed -n 2p "$dd.out")"
eq "split leaves a pointer" "1" "$(sed -n 3p "$dd.out")"
eq "split keeps the rest of the brief" "1" "$(sed -n 4p "$dd.out")"
eq "split numbers decisions by file" "decision docs/decisions/*.md" "$(sed -n 5p "$dd.out")"
eq "list reads them back" "| D2 | 2026-10-02 | Second thing. |" "$(sed -n 6p "$dd.out")"

printf '\n# batches and the drain, sharing pull requests\n'
eq "a batch body's members" "303
305" "$(batch_members "$(batch_pr_body "$(printf '303\tAI fill\n305\tHighlights\n')")")"
eq "the drain drops an open batch's members" "301	false	sha	main" "$(drop_members "$(printf '301\tfalse\tsha\tmain\n303\tfalse\tsha\tmain\n305\tfalse\tsha\tmain')" '303 305')"
eq "and the batch itself" "" "$(drop_members "$(printf '306\tfalse\tsha\tmain')" '303 305 306')"
eq "no batch open, nothing dropped" "301	false	sha	main" "$(drop_members "$(printf '301\tfalse\tsha\tmain')" '')"
eq "jobs waiting on machines are said with a rough time" "6 job(s) queued, 2 of 2 runner(s) busy; about 12 minute(s) at one job per runner. Waiting on machines, not on a failure." "$(queue_eta 6 2 2 4)"
eq "queued with no runner online" "3 job(s) queued and no runner online." "$(queue_eta 3 0 0)"
eq "nothing queued, nothing said" "" "$(queue_eta 0 2 2)"

printf '\n# a batch anchored on the earliest pull request\n'
eq "no conflicts, everyone in" "251 252 253" "$(anchored_group '251 252 253' '' | tr '\n' ' ' | sed 's/ $//')"
eq "the earliest stays in, its conflicts go" "251 254" "$(anchored_group '251 252 253 254' "$(printf '251 252\n251 253')" | tr '\n' ' ' | sed 's/ $//')"
eq "the largest set beside the earliest, not the first that fits" "251 253 254" "$(anchored_group '251 252 253 254' "$(printf '252 253\n252 254')" | tr '\n' ' ' | sed 's/ $//')"
eq "on a tie, the earlier one" "251 252" "$(anchored_group '251 252 253' "$(printf '252 253')" | tr '\n' ' ' | sed 's/ $//')"
eq "one pull request is its own batch" "251" "$(anchored_group '251' '')"
eq "the notice names the files and the fix" "yes" "$(conflict_notice "$(printf 'src/cart.ts\nsrc/a.ts')" 252 | grep -q '#252, which goes into this batch first in:' && conflict_notice 'src/cart.ts' main | grep -q 'Never rebase or force-push' && echo yes)"
eq "conflicts are noticed once per head commit" "1" "$(grep -cF 'grep -qx "$1 $nc_sha" "$nc_seen"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the queue notices in all three places" "3" "$(grep -c '^ *notify_conflict "\$pr"' "$root/templates/scripts/ci/merge-queue.sh")"

printf '\n# when a green pull request needs a second run\n\'
eq "main moved outside its classes: merge" "merge" "$(rerun_decision no red)"
eq "main moved in its classes and main is green: merge, main's run is the gate" "merge" "$(rerun_decision yes green)"
eq "main is red: re-run" "update" "$(rerun_decision yes red)"
eq "main's newest commit has not finished its run: re-run" "update" "$(rerun_decision yes pending)"
eq "main unreadable: re-run" "update" "$(rerun_decision yes unknown)"
eq "the old rule on request" "update" "$(rerun_decision yes green classes)"

printf '\n# labels over REST, and waiting on a machine\n'
eq "the state label replaces the old one and keeps the rest" '{"labels":["bug","task","state:in-progress"]}' "$(state_labels_json 'bug
state:ready
task' 'state:in-progress')"
eq "no labels yet" '{"labels":["state:ready"]}' "$(state_labels_json '' 'state:ready')"
eq "a quote in a label survives" '{"labels":["say \"hi\"","state:ready"]}' "$(state_labels_json 'say "hi"' 'state:ready')"
eq "all queued is waiting on a machine" "yes" "$(checks_queued_only 'queued
queued
completed')"
eq "one running is waiting on tests" "no" "$(checks_queued_only 'queued
in_progress')"
eq "nothing queued is not" "no" "$(checks_queued_only 'completed')"
eq "queued with no runner online: stop" "stop" "$(runner_stall yes 0)"
eq "queued with a runner online: wait" "" "$(runner_stall yes 1)"
eq "queued and the runners unreadable: say so" "unknown" "$(runner_stall yes unknown)"
eq "running: wait" "" "$(runner_stall no 0)"

printf '\n# serial merges, enforced by the queue\n'
eq "alone with nothing else ready may go" "" "$(serial_refusal '' '')"
eq "a reason always may go" "" "$(serial_refusal '81 82 83' migration)"
eq "others ready and no reason is refused, naming them" "3 other green pull request(s) are ready to land with it (#81 #82 #83); merge them together with --drain (or --batch), or give the reason this one must land alone: --serial N --because migration|conflict|must-land-alone|\"why\"" "$(serial_refusal '81 82 83 ' '')"
eq "the reason goes in the squash title" "Fix the chime (#79) [serial: migration]" "$(serial_title 'Fix the chime' 79 migration)"
eq "no reason is alone" "Fix it (#80) [serial: alone]" "$(serial_title 'Fix it' 80 '')"
eq "three serial merges in an hour are a burst" "Main took 3 serial merges within an hour (reasons: alone, alone, migration). Pull requests that are ready together should land as one batch: sh scripts/ci/merge-queue.sh --drain." "$(serial_bursts "$(printf '3000\tC (#3) [serial: migration]\n2000\tB (#2) [serial: alone]\n1000\tA (#1) [serial: alone]\n500\tMerge pull request #9 from x/batch-1\n')")"
eq "two are not" "" "$(serial_bursts "$(printf '2000\tB (#2) [serial: alone]\n1000\tA (#1) [serial: alone]\n')")"
eq "three spread over a day are not" "" "$(serial_bursts "$(printf '20000\tC [serial: alone]\n10000\tB [serial: alone]\n1000\tA [serial: alone]\n')")"
eq "a conflict names its files" "conflicts with main in web/src/a.ts docs/product-brief.md; resolve it on the branch, then queue it again" "$(conflict_line 'web/src/a.ts
docs/product-brief.md')"
eq "a conflict with no files named still says so" "conflicts with main; resolve it on the branch, then queue it again" "$(conflict_line '')"
eq "the queue waits on the CI workflow's run, not the newest of any" "1" "$(grep -c -- '--workflow "${QUEUE_CI_WORKFLOW:-ci.yml}"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "agent worktrees are a known place, not a stray folder" "Worktrees: 2 besides the main checkout, in 1 folder, and 1 made by Claude Code for dispatched agents in .claude/worktrees." "$(worktree_summary 'worktree C:/r/app
worktree C:/r/app-wt/a
worktree C:/r/app-wt/b
worktree C:/r/app/.claude/worktrees/agent-1')"

printf '\n# the API budget and one queue at a time\n'
eq "plenty left, no wait" "0" "$(rate_wait "4000	2000" 1000)"
eq "under the floor, wait until the reset" "600" "$(rate_wait "120	1600" 1000)"
eq "under the floor but the window has reset" "0" "$(rate_wait "120	900" 1000)"
eq "a custom floor" "0" "$(rate_wait "120	1600" 1000 100)"
eq "unknown budget, no wait" "0" "$(rate_wait '' 1000)"
eq "a reset a second away waits one second" "1" "$(rate_wait "0	1001" 1000)"
eq "a 403 for the rate limit is named" "yes" "$(rate_limit_hit 'HTTP 403: API rate limit exceeded for user ID 1 (https://api.github.com/repos/x/y/actions/runs)')"
eq "a secondary limit too" "yes" "$(rate_limit_hit 'You have exceeded a secondary rate limit')"
eq "another error is not" "no" "$(rate_limit_hit 'HTTP 404: Not Found')"
eq "no error is not" "no" "$(rate_limit_hit '')"
eq "a running drain refuses a second queue" "a --drain started 12 minute(s) ago is still running (pid 4242)" "$(queue_lock_reason "4242	1000	--drain" 1720 yes)"
eq "a running queue's status" "running: a --drain started 12 minute(s) ago is still running (pid 4242); last line: 10:02 merged #51" "$(queue_status "a --drain started 12 minute(s) ago is still running (pid 4242)" "10:02 merged #51")"
eq "an idle queue's status" "idle; last line: 10:05 queue done (exit 0); lock released" "$(queue_status "" "10:05 queue done (exit 0); lock released")"
eq "idle with no log yet" "idle" "$(queue_status "" "")"
eq "the queue's last word goes to the log after the lock" "yes" "$(grep -q 'queue done (exit \$qe_rc); lock released' "$root/templates/scripts/ci/merge-queue.sh" && grep -c 'echo "queue done"' "$root/templates/scripts/ci/merge-queue.sh" | awk '{ print ($1 == 1) ? "yes" : "no: " $1 }')"
eq "prose in a quoted body is not a merge" "" "$(batch_merge_reason "printf 'Run merge-queue.sh 1 2 3 4 5 or --force' > .scratch/issue.md && gh api repos/{owner}/{repo}/issues -f title=t -F body=@.scratch/issue.md")"
eq "the real invocation beside the prose still counts" "3" "$(batch_merge_reason "echo 'merge-queue.sh is fine' && sh scripts/ci/merge-queue.sh 1 2 3")"
eq "a quoted gh pr merge is prose" "" "$(direct_merge_reason "printf 'never run gh pr merge 12' >> notes.md")"
eq "the pull request template shows both parity forms" "2" "$(grep -c '^Parity: ' "$root/templates/.github/pull_request_template.md")"
eq "CI diffs a pull request from current main, the merge ref's first parent" "1 1" "$(grep -c "BASE: \${{ github.event_name == 'pull_request' && 'HEAD^1' || github.event.before }}" "$root/templates/.github/workflows/ci.yml") $(grep -c 'base=$(git rev-parse "$head^1")' "$root/templates/scripts/ci/design-check.sh")"
gen_cfg_t='# built output
packages/core/*
rebuild: ./gradlew :core:jsPackage
'
eq "the generated globs" "packages/core/*" "$(generated_globs "$gen_cfg_t")"
eq "the rebuild command" "./gradlew :core:jsPackage" "$(rebuild_command "$gen_cfg_t")"
eq "a conflict only in generated files" "yes" "$(generated_only "$(printf 'packages/core/index.js\npackages/core/types.d.ts')" "$gen_cfg_t")"
eq "a conflict that reaches source is not" "no" "$(generated_only "$(printf 'packages/core/index.js\nandroid/core/src/Core.kt')" "$gen_cfg_t")"
eq "no list, never generated-only" "no" "$(generated_only 'packages/core/index.js' '# nothing listed')"
eq "no files, not generated-only" "no" "$(generated_only '' "$gen_cfg_t")"
eq "the drop line says when a rebuild would have done" "conflicts with main in packages/core/index.js; generated only: a rebuild on the batch would resolve this; resolve it on the branch, then queue it again" "$(conflict_line 'packages/core/index.js' generated)"
eq "the conflict comment too" "1" "$(conflict_notice 'packages/core/index.js' main generated | grep -c 'generated build output')"
eq "a plain conflict comment says nothing of it" "0" "$(conflict_notice 'src/a.ts' main | grep -c 'generated build output')"
eq "the batch takes either side of generated files and rebuilds" "1 1" "$(grep -c 'merge -q --no-ff --no-edit -X theirs' "$root/templates/scripts/ci/merge-queue.sh") $(grep -c 'rb=$(rebuild_command "$gen_cfg")' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a lock whose process is gone is free" "" "$(queue_lock_reason "4242	1000	--drain" 1720 no)"
eq "a lock older than three hours is free" "" "$(queue_lock_reason "4242	1000	--batch" 20000 yes)"
eq "no lock is free" "" "$(queue_lock_reason '' 1720 yes)"

printf '\n# the package a file belongs to\n'
roots='.
web
web/packages/ui
tools'
eq "a file in the web app runs from web" "web" "$(nearest_root 'web/src/a.test.ts' "$roots")"
eq "the deepest package wins" "web/packages/ui" "$(nearest_root 'web/packages/ui/b.test.ts' "$roots")"
eq "a file outside every package runs from the root" "." "$(nearest_root 'scripts/x.test.ts' "$roots")"
eq "Windows separators are fine" "web" "$(nearest_root 'web\src\a.test.ts' "$roots")"
eq "a sibling name is not a prefix" "." "$(nearest_root 'webapp/a.test.ts' "$roots")"
eq "no root at all, nothing" "" "$(nearest_root 'a.test.ts' 'web')"

printf '\n# numbering\n'
. "$root/templates/scripts/ci/numbering-lib.sh"
eq "the glob for a kind" "supabase/migrations/*.sql" "$(numbering_glob '# note
migration supabase/migrations/*.sql
seed seed/*.json' migration)"
eq "an unknown kind" "" "$(numbering_glob 'migration m/*.sql' setup)"
eq "migrations in supabase/migrations are found" "supabase/migrations/*.sql" "$(migration_glob_guess 'web/src/a.ts
supabase/migrations/0040_x.sql
supabase/config.toml')"
eq "root migrations are found" "migrations/*.sql" "$(migration_glob_guess 'migrations/0001_init.sql')"
eq "supabase wins when both exist" "supabase/migrations/*.sql" "$(migration_glob_guess 'migrations/0001.sql
supabase/migrations/0002.sql')"
eq "no migrations, no guess" "" "$(migration_glob_guess 'src/a.ts')"
paths='supabase/migrations/0021_chime_volume.sql
supabase/migrations/0022_station_chime_volume.sql
supabase/migrations/README.md
docs/0099_not_a_migration.sql
supabase\migrations\0023_testing_program.sql'
eq "numbers of matching files, padding kept, either slash" "0021
0022
0023" "$(numbers_in "$paths" 'supabase/migrations/*.sql')"
eq "the next free number" "0024" "$(next_free_number "$(numbers_in "$paths" 'supabase/migrations/*.sql')")"
eq "the first number when there are none" "0001" "$(next_free_number '')"
eq "padding follows the widest number" "00008" "$(next_free_number '00007
3')"
eq "two files sharing a number" "0022	0022_a.sql 0022_b.sql" "$(duplicate_numbers 'm/0021_x.sql
m/0022_a.sql
m/0022_b.sql' 'm/*.sql')"
eq "22 and 0022 are the same number" "0022	22_a.sql 0022_b.sql" "$(duplicate_numbers 'm/22_a.sql
m/0022_b.sql' 'm/*.sql')"
eq "no duplicates, nothing" "" "$(duplicate_numbers 'm/0021_x.sql
m/0022_y.sql' 'm/*.sql')"
eq "running task numbers are found" "## 14. Add the exporter
- [ ] 7: Fix the chime
T12) Rename the page
7p. Run the migration" "$(running_task_lines '## 14. Add the exporter
- [ ] 7: Fix the chime
T12) Rename the page
7p. Run the migration
## #231 Add the exporter
- [ ] #232 Fix the chime
Some prose with 3. in the middle')"
eq "issue-numbered tasks pass" "" "$(running_task_lines '## #231 Add the exporter
- [x] #45 Ship it')"
manual=$(cat "$fx/setup-manual.md")
eq "a migration still not run" "0024_station_chimes_off.sql	not yet run" "$(pending_migrations "$manual" 'supabase/migrations/0024_station_chimes_off.sql
src/chimes.ts' 'supabase/migrations/*.sql')"
eq "a migration marked done passes, even with the instruction text" "" "$(pending_migrations "$manual" 'supabase/migrations/0007_schedule_versions.sql' 'supabase/migrations/*.sql')"
eq "a migration the manual never mentions" "0025_new.sql	not in the manual" "$(pending_migrations "$manual" 'supabase/migrations/0025_new.sql' 'supabase/migrations/*.sql')"
eq "no migration added, nothing" "" "$(pending_migrations "$manual" 'src/a.ts' 'supabase/migrations/*.sql')"
eq "a manual line without the extension still counts, and still blocks when not yet run" "0002_profiles.sql	not yet run" "$(pending_migrations '| 0002_profiles | Not yet run |' 'supabase/migrations/0002_profiles.sql' 'supabase/migrations/*.sql')"
eq "a manual line without the extension marked done passes" "" "$(pending_migrations '| 0002_profiles | Done 2026-10-10 |' 'supabase/migrations/0002_profiles.sql' 'supabase/migrations/*.sql')"

printf '\n# decision numbers inside a file\n'
brief='## Decisions

| ID | Decision | Date |
|---|---|---|
| D1 | Repo and board 5 are the source of truth. | 2026-09-25 |
| D2 | One-time price. | 2026-09-26 |
| D55 | Chimes per station. | 2026-10-07 |

The chime (D34) and the price (D38) are referenced here, not defined.
- **D56** Volume per station.
## D57 Wear tiles'
eq "the kind's prefix" "D" "$(numbering_prefix 'migration m/*.sql
decision docs/product-brief.md D' decision)"
eq "a file-name kind has no prefix" "" "$(numbering_prefix 'migration m/*.sql' migration)"
eq "definitions in table rows, bold and headings, not prose" "1
2
55
56
57" "$(id_definitions "$brief" D)"
eq "D10 is not a definition of D1" "10" "$(id_definitions '| D10 | x |' D)"
eq "a word that only starts with the prefix is not a definition" "" "$(id_definitions '- Done 2026-10-05' D)"
eq "no duplicates in a clean brief" "" "$(duplicate_ids "$brief" D)"
eq "two pull requests that both took D55" "D55" "$(duplicate_ids "$brief
| D55 | Another decision. | 2026-10-08 |" D)"
eq "the next free decision" "D58" "$(next_free_id "$(id_definitions "$brief" D)" D)"
eq "the first decision" "D1" "$(next_free_id '' D)"

printf '\n# env-lib\n'
. "$root/templates/scripts/env-lib.sh"
eq "a missing key is appended" "A=1
B=2" "$(env_set 'A=1' B 2)"
eq "an existing key is replaced in place" "# db
A=9
B=2" "$(env_set '# db
A=1
B=2' A 9)"
eq "an export prefix survives" "export A=9" "$(env_set 'export A=1' A 9)"
eq "a key that is a prefix of another is not touched" "AB=1
A=9" "$(env_set 'AB=1' A 9)"
eq "empty text gets the one line" "A=9" "$(env_set '' A 9)"
eq "a password is the asked length" "32" "$(random_password 32 | tr -d '\n' | wc -c | tr -d ' ')"
eq "a password is letters and digits only" "0" "$(random_password 32 | tr -d 'A-Za-z0-9\n' | wc -c | tr -d ' ')"
eq "two passwords differ" "no" "$([ "$(random_password)" = "$(random_password)" ] && echo yes || echo no)"

printf '\n# template refresh\n'
. "$root/scripts/sync/sync-lib.sh"
owned='# comment
scripts/ci/merge-queue.sh
.github/workflows/audit.yml
default scripts/ci/task-files.txt'
eq "plugin-owned paths" "scripts/ci/merge-queue.sh
.github/workflows/audit.yml" "$(owned_paths "$owned")"
eq "config with defaults" "scripts/ci/task-files.txt" "$(default_paths "$owned")"
eq "secrets and variables a workflow reads" "secrets PROJECT_TOKEN, QUEUE_TOKEN; variables BOARD_NUMBER" "$(workflow_needs 'token: ${{ secrets.QUEUE_TOKEN }}
env: ${{ secrets.PROJECT_TOKEN }} ${{ vars.BOARD_NUMBER }} ${{ secrets.QUEUE_TOKEN }}')"
eq "a workflow that reads none says nothing" "" "$(workflow_needs 'run: echo hi')"
eq "runs-on from a project workflow" "[self-hosted, windows]" "$(ci_runs_on 'jobs:
  a:
    runs-on: [self-hosted, windows]
  b:
    runs-on: ubuntu-latest')"
eq "a RUNS_ON placeholder is not a value" "" "$(ci_runs_on '    runs-on: RUNS_ON')"
eq "an expression is never copied as a runner" "[self-hosted, windows]" "$(ci_runs_on '    runs-on: ${{ fromJSON(needs.plan.outputs.runner) }}
    runs-on: [self-hosted, windows]')"
owned_txt='feature core
scripts/ci/lib.sh
feature board
scripts/state.sh
scripts/board.sh
feature deploy
scripts/deploy-setup.sh
default scripts/ci/classes.txt'
feats=$(owned_features "$owned_txt")
eq "owned paths skip feature lines" "scripts/ci/lib.sh
scripts/state.sh
scripts/board.sh
scripts/deploy-setup.sh" "$(owned_paths "$owned_txt")"
eq "a path's feature" "board" "$(feature_of "$feats" scripts/board.sh)"
eq "a feature is not used for one stray file, only its anchor" "core" "$(adopted_features "$feats" 'scripts/ci/lib.sh
scripts/board.sh')"
eq "features a project uses: their anchors are here" "core deploy" "$(adopted_features "$feats" 'scripts/ci/lib.sh
scripts/deploy-setup.sh')"
eq "a project with its own board tools has none of the plugin's: not used" "core" "$(adopted_features "$feats" 'scripts/ci/lib.sh
scripts/board-state.sh')"
eq "the shell from a project workflow, quotes kept" "'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'" "$(ci_shell "defaults:
  run:
    shell: 'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'")"
eq "a RUN_SHELL placeholder is not a value" "" "$(ci_shell '    shell: RUN_SHELL')"
eq "a Windows shell path is filled with its backslashes intact" "    shell: 'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'" "$(fill_placeholder '    shell: RUN_SHELL' RUN_SHELL "'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'")"
eq "a workflow is compared with the project's runner and shell filled" "    runs-on: [self-hosted, windows]
    shell: bash" "$(filled_text "$(printf '    runs-on: RUNS_ON\n    shell: RUN_SHELL')" '[self-hosted, windows]' bash)"
eq "an empty value leaves its placeholder" "    runs-on: RUNS_ON" "$(filled_text '    runs-on: RUNS_ON' '' '')"
for hk in state-label board-sync audit; do
  eq "$hk runs where the project's CI runs" "0" "$(grep -v '^#' "$root/templates/.github/workflows/$hk.yml" | grep -c 'ubuntu-latest')"
done
eq "Deploy's plan and Vercel deploy follow ci.yml's runner and shell" "0" "$(grep -c 'DEPLOY_JOBS_ON ||' "$root/templates/.github/workflows/deploy.yml")"
eq "no bare bash where Deploy follows ci.yml" "0" "$(awk '/^  plan:$/{j=1} /^  build-on-runner:$/{j=0} /^  build-on-vercel:$/{j=1} j && /shell: bash$/{n++} END{print n+0}' "$root/templates/.github/workflows/deploy.yml")"
eq "a Windows QUEUE_RUNS_ON gets Git's bash" "1" "$(grep -c 'PROGRA~1\\Git\\bin\\bash.exe' "$root/templates/.github/workflows/queue-drain.yml")"
eq "both drain jobs share one list of steps" "1 1" "$(grep -c 'steps: &drain-steps' "$root/templates/.github/workflows/queue-drain.yml") $(grep -c 'steps: \*drain-steps' "$root/templates/.github/workflows/queue-drain.yml")"
eq "the placeholder check reads whole words" "0" "$(printf 'runs-on: ${{ vars.QUEUE_RUNS_ON }}\n' | grep -cw 'RUNS_ON\|RUN_SHELL')"
eq "only the guarded smoke check stays hosted" "smoke.yml" "$(cd "$root/templates/.github/workflows" && grep -l 'runs-on: ubuntu-latest' *.yml | paste -sd' ' -)"
eq "state-label runs once per issue per burst" "1" "$(grep -c 'group: state-label-\${{ github.event.issue.number }}' "$root/templates/.github/workflows/state-label.yml")"
eq "a scheduled deploy with interval 0 does nothing" "1" "$(grep -c 'intervalMinutes is 0' "$root/templates/.github/workflows/deploy.yml")"
# --- The sync judges a file by its content against every released version.
eq "unfill puts a project's runner back to its placeholder" "    runs-on: RUNS_ON
    shell: RUN_SHELL" "$(unfill_text "$(printf '    runs-on: [self-hosted, windows]\n    shell: bash')" '[self-hosted, windows]' bash)"
eq "unfill leaves another runner alone" "    runs-on: ubuntu-latest" "$(unfill_text '    runs-on: ubuntu-latest' '[self-hosted, windows]' bash)"
eq "a workflow's scripts are found" "scripts/ci/lib.sh
scripts/board-sync.sh" "$(sourced_scripts "$(printf '        run: |\n          . scripts/ci/lib.sh\n          sh scripts/board-sync.sh 8 me\n')")"
eq "a script tested for first is optional" "" "$(sourced_scripts "$(printf '          if [ -f scripts/ci/batch-lib.sh ]; then\n            . scripts/ci/batch-lib.sh\n          fi\n')")"
km_known="$(printf 'a/x.yml %s\n' "$(norm_hash "$(printf '    runs-on: RUNS_ON')")")"
eq "a filled workflow matches its released version" "yes" "$(known_match "$km_known" a/x.yml '    runs-on: [self-hosted]' '[self-hosted]' '')"
eq "a project's own file matches none" "no" "$(known_match "$km_known" a/x.yml '    runs-on: [mine]' '[self-hosted]' '')"
km_missing=$(for p in $(owned_paths "$(cat "$root/templates/OWNED.txt")"); do grep -qxF "$p $(norm_hash "$(cat "$root/templates/$p")")" "$root/templates/KNOWN.txt" || echo "$p"; done)
eq "every current template is in KNOWN.txt (run scripts/sync/known-hashes.sh before a release)" "" "$km_missing"

# Release bump: one script sets the version everywhere
rb_pv=$(sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' "$root/.claude-plugin/plugin.json")
rb_kv=$(sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' "$root/package.json")
rb_bv=$(grep 'img.shields.io/badge/version-' "$root/README.md" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | sort -u)
eq "plugin.json, package.json and the README badge agree on the version" "$rb_pv" "$rb_kv"
eq "the README badge line carries only that version" "$rb_pv" "$rb_bv"
rb_d=$(mktemp -d)
mkdir -p "$rb_d/plugin/scripts/release" "$rb_d/plugin/.claude-plugin"
cp "$root/scripts/release/bump.sh" "$rb_d/plugin/scripts/release/"
cp "$root/.claude-plugin/plugin.json" "$rb_d/plugin/.claude-plugin/"
cp "$root/package.json" "$root/README.md" "$rb_d/plugin/"
rb_run() { (cd "$rb_d" && sh plugin/scripts/release/bump.sh "$@" --no-known >/dev/null 2>&1); }
rb_ver() { sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' "$1"; }
rb_all() { cat "$rb_d/plugin/.claude-plugin/plugin.json" "$rb_d/plugin/package.json" "$rb_d/plugin/README.md" | cksum; }
rb_run 9.8.7
eq "bump sets plugin.json" "9.8.7" "$(rb_ver "$rb_d/plugin/.claude-plugin/plugin.json")"
eq "bump sets package.json" "9.8.7" "$(rb_ver "$rb_d/plugin/package.json")"
eq "bump sets both places on the badge line" "9.8.7" "$(grep 'img.shields.io/badge/version-' "$rb_d/plugin/README.md" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | sort -u)"
eq "bump leaves the other badges alone" "$(grep -c 'img.shields.io' "$root/README.md")" "$(grep -c 'img.shields.io' "$rb_d/plugin/README.md")"
rb_sum=$(rb_all)
rb_run 9.8.7
eq "bump twice with the same version changes nothing" "$rb_sum" "$(rb_all)"
eq "bump refuses a bad version" "2" "$(cd "$rb_d" && sh plugin/scripts/release/bump.sh 1.2 --no-known >/dev/null 2>&1; echo $?)"
eq "bump refuses a version with a suffix" "2" "$(cd "$rb_d" && sh plugin/scripts/release/bump.sh 1.2.3-beta --no-known >/dev/null 2>&1; echo $?)"

# The sync in a throwaway project: its own workflow is never replaced, and
# a workflow is refused rather than written broken.
ss_new() {
  ss_d=$(mktemp -d)
  git -C "$ss_d" init -q -b main
  git -C "$ss_d" config user.email t@example.com; git -C "$ss_d" config user.name t
  mkdir -p "$ss_d/scripts" "$ss_d/.github/workflows"
  cp "$root/templates/scripts/board-lib.sh" "$ss_d/scripts/board-lib.sh"
  echo "$ss_d"
}
ss_d=$(ss_new)
printf 'name: Our own audit\non: workflow_dispatch\njobs:\n  a:\n    runs-on: [self-hosted]\n    steps:\n      - run: echo ours\n' > "$ss_d/.github/workflows/audit.yml"
printf 'jobs:\n  checks:\n    runs-on: [self-hosted, windows]\n    defaults:\n      run:\n        shell: bash\n' > "$ss_d/.github/workflows/ci.yml"
git -C "$ss_d" add -A; git -C "$ss_d" commit -q -m start
ss_out=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --apply --force --no-commit 2>&1)
eq "a project's own workflow is named as its own" "1" "$(printf '%s\n' "$ss_out" | grep -c 'own:      .github/workflows/audit.yml')"
eq "and never replaced, --force included" "name: Our own audit" "$(head -n 1 "$ss_d/.github/workflows/audit.yml")"
eq "a workflow's missing plugin script comes with it" "1 yes yes" "$(printf '%s\n' "$ss_out" | grep -c 'brings:   scripts/ci/lib.sh') $([ -f "$ss_d/scripts/ci/lib.sh" ] && echo yes || echo no) $([ -f "$ss_d/.github/workflows/state-label.yml" ] && echo yes || echo no)"

ss_d=$(ss_new)
mkdir -p "$ss_d/scripts/ci"; cp "$root/templates/scripts/ci/lib.sh" "$ss_d/scripts/ci/lib.sh"
git -C "$ss_d" add -A; git -C "$ss_d" commit -q -m start
ss_out=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --apply --no-commit 2>&1)
eq "with no runner to copy, a workflow is refused, not written with RUNS_ON" "1 no" "$(printf '%s\n' "$ss_out" | grep -c 'refused:  .github/workflows/state-label.yml needs to know') $([ -f "$ss_d/.github/workflows/state-label.yml" ] && echo yes || echo no)"
eq "a script name at the end of a sentence loses its period" "scripts/ci/runner-doctor.sh" "$(sourced_scripts 'Run sh scripts/ci/runner-doctor.sh.')"
eq "a script's loads are its dependencies, a command it only prints is not" "scripts/ci/lib.sh" "$(loaded_scripts "$(printf '. scripts/ci/lib.sh\necho "run sh scripts/worktrees.sh"\n')")"
eq "a script's own-folder dependencies are found" "scripts/ci/doctor-lib.sh" "$(here_scripts '. "$here/doctor-lib.sh"' scripts/ci)"
ss_d=$(ss_new)
printf 'jobs:\n  checks:\n    runs-on: [self-hosted, windows]\n    defaults:\n      run:\n        shell: bash\n' > "$ss_d/.github/workflows/ci.yml"
# The retired hosted Runner watch: a plugin copy goes with --apply, since
# in a private repository whose hosted minutes are used up it failed at
# every schedule.
git -C "$root" show 2b7b360:plugin/templates/.github/workflows/runner-watch.yml > "$ss_d/.github/workflows/runner-watch.yml"
git -C "$ss_d" add -A; git -C "$ss_d" commit -q -m start
ss_dry=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" 2>&1)
eq "the retired runner watch is named to go" "1" "$(printf '%s\n' "$ss_dry" | grep -c 'watch:    .github/workflows/runner-watch.yml goes')"
eq "the dry run prints the same refusals as --apply" "$(printf '%s\n' "$ss_dry" | grep '^  refused:' | sort)" "$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --apply --no-commit 2>&1 | grep '^  refused:' | sort)"
eq "and --apply removes the retired runner watch, staged" "no D" "$([ -f "$ss_d/.github/workflows/runner-watch.yml" ] && echo yes || echo no) $(git -C "$ss_d" diff --cached --name-status -- .github/workflows/runner-watch.yml | cut -c1)"

# A template file OWNED.txt does not list is new, and arrives with --apply:
# a project synced to 0.24.0 never got the mock check's scripts.
fixtures_sync="$root/tests/fixtures/sync"
eq "a template script OWNED.txt does not list is new" "scripts/ci/mock-check.sh" "$(new_template_files "$(printf 'scripts/ci/lib.sh\nscripts/ci/mock-check.sh\nCLAUDE.md\n')" "scripts/ci/lib.sh")"
ss_d=$(ss_new)
while IFS= read -r nf_p; do mkdir -p "$ss_d/$(dirname "$nf_p")"; cp "$root/templates/$nf_p" "$ss_d/$nf_p"; done < "$fixtures_sync/new-files-project.txt"
git -C "$ss_d" add -A; git -C "$ss_d" commit -q -m start
ss_dry=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" 2>&1)
eq "the dry run lists the new check scripts" "3" "$(printf '%s\n' "$ss_dry" | grep -c 'new:      scripts/ci/mock-check.sh\|new:      scripts/ci/mock-lib.sh\|new:      scripts/ci/mocks.txt')"
eq "a new file goes only where its folder is" "0" "$(printf '%s\n' "$ss_dry" | grep -c 'new:      scripts/design/')"
(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --apply --no-commit >/dev/null 2>&1)
eq "and --apply adds them" "yes yes" "$([ -f "$ss_d/scripts/ci/mock-check.sh" ] && echo yes || echo no) $(git -C "$ss_d" diff --cached --name-only | grep -qx scripts/ci/mock-lib.sh && echo yes || echo no)"

# A filled workflow the project edited is not kept whole: a template step
# its copy lacks is carried in by name, and its own steps stay.
cs_tpl=$(filled_text "$(cat "$root/templates/.github/workflows/ci.yml")" '[self-hosted, windows]' bash)
cs_p=$(cat "$fixtures_sync/ci-lacks-steps.yml")
eq "the steps a job lacks are named" "yes" "$(missing_steps "$cs_tpl" "$cs_p" | grep -qxF "$(printf 'checks\tFail when a screen changes and its mock does not')" && echo yes || echo no)"
eq "a job the project lacks is not a step it lacks" "0" "$(missing_steps "$cs_tpl" "$cs_p" | grep -c '^app	')"
eq "a step the project has is not missing" "0" "$(missing_steps "$cs_tpl" "$cs_p" | grep -c 'Classify the change')"
cs_out=$(carry_steps "$cs_tpl" "$cs_p")
eq "after carrying, the job lacks nothing" "" "$(missing_steps "$cs_tpl" "$cs_out" | grep '^checks	')"
eq "its own step and its runner are kept" "1 2" "$(printf '%s\n' "$cs_out" | grep -c 'name: Our own lint') $(printf '%s\n' "$cs_out" | grep -c 'runs-on: \[self-hosted, windows\]')"
eq "a carried step lands after the one before it in the template" "Classify the change|Fail when a text file has CRLF endings" "$(printf '%s\n' "$cs_out" | sed -n 's/^      [ -]*name: //p' | sed -n '1,2p' | tr '\n' '|' | sed 's/|$//')"
eq "the next job is untouched" "Report once for every job" "$(printf '%s\n' "$cs_out" | awk '/^  ci-passed:/{f=1} f && /name:/{sub(/.*name: /,""); print; exit}')"
eq "carrying into a complete copy changes nothing" "same" "$([ "$(carry_steps "$cs_tpl" "$cs_tpl")" = "$cs_tpl" ] && echo same || echo differs)"
ss_d=$(ss_new)
cp "$fixtures_sync/ci-lacks-steps.yml" "$ss_d/.github/workflows/ci.yml"
git -C "$ss_d" add -A; git -C "$ss_d" commit -q -m start
ss_dry=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" 2>&1)
eq "the dry run names the step ci.yml lacks" "1" "$(printf '%s\n' "$ss_dry" | grep -c 'step:     .github/workflows/ci.yml job checks lacks the template.s step "Fail when a screen changes and its mock does not"')"
(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --apply --no-commit >/dev/null 2>&1)
eq "and --apply carries it into ci.yml, keeping its own step" "1 1" "$(grep -c 'Fail when a screen changes and its mock does not' "$ss_d/.github/workflows/ci.yml") $(grep -c 'Our own lint' "$ss_d/.github/workflows/ci.yml")"

# A template step whose body is only a placeholder is not carried into a
# copy that replaced it with its own steps; the report says so.
pl_p=$(cat "$fixtures_sync/ci-replaced-placeholder.yml")
eq "a placeholder step is named, marked as one" "full	Run everything	placeholder" "$(missing_steps "$cs_tpl" "$pl_p" | grep 'Run everything')"
eq "a placeholder step is not carried" "0" "$(carry_steps "$cs_tpl" "$pl_p" | grep -c 'Run everything')"
eq "the copy's own steps stay when a placeholder is skipped" "same" "$([ "$(carry_steps "$cs_tpl" "$pl_p")" = "$pl_p" ] && echo same || echo differs)"
ss_d=$(ss_new)
cp "$fixtures_sync/ci-replaced-placeholder.yml" "$ss_d/.github/workflows/ci.yml"
git -C "$ss_d" add -A; git -C "$ss_d" commit -q -m start
ss_dry=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" 2>&1)
eq "the dry run says the placeholder is not carried" "1" "$(printf '%s\n' "$ss_dry" | grep -c 'step:     .github/workflows/ci.yml job full lacks the template.s step "Run everything"; placeholder, not carried')"
(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --apply --no-commit >/dev/null 2>&1)
eq "and --apply leaves it out of ci.yml" "0" "$(grep -c 'Run everything\|replace with' "$ss_d/.github/workflows/ci.yml")"
# A filled workflow must read back as a released version, whatever the
# project's runner and shell: the fill leaves comments alone, the
# templates hold no literal line a fill could produce, and a workflow an
# earlier sync filled with its comments still matches.
km_known=$(cat "$root/templates/KNOWN.txt")
km_bad=""
for km_wf in audit board-sync state-label deploy queue-drain runner-watch runner-check; do
  [ -f "$root/templates/.github/workflows/$km_wf.yml" ] || continue
  for km_sh in bash "'C:\\PROGRA~1\\Git\\bin\\bash.exe --noprofile --norc -eo pipefail {0}'"; do
    km_t=$(filled_text "$(cat "$root/templates/.github/workflows/$km_wf.yml")" "[self-hosted, windows]" "$km_sh")
    [ "$(known_match "$km_known" ".github/workflows/$km_wf.yml" "$km_t" "[self-hosted, windows]" "$km_sh")" = yes ] || km_bad="$km_bad $km_wf($km_sh)"
  done
done
eq "every filled workflow reads back as the plugin's, with a bash or a Windows shell" "" "$km_bad"
eq "a comment that names the placeholders is not filled" "# RUNS_ON and RUN_SHELL here
    runs-on: [self-hosted]
    shell: bash" "$(filled_text "$(printf '# RUNS_ON and RUN_SHELL here\n    runs-on: RUNS_ON\n    shell: RUN_SHELL')" '[self-hosted]' bash)"
km_old=$(fill_placeholder "$(fill_placeholder "$(cat "$root/templates/.github/workflows/audit.yml")" RUNS_ON '[self-hosted, windows]')" RUN_SHELL bash)
eq "a workflow an earlier sync filled, comments included, still matches" "yes" "$(known_match "$km_known" .github/workflows/audit.yml "$km_old" '[self-hosted, windows]' bash)"
eq "but a changed one does not" "no" "$(known_match "$km_known" .github/workflows/audit.yml "$(printf '%s\n      - run: echo mine\n' "$km_old")" '[self-hosted, windows]' bash)"
# On the guard path Deploy has nothing to do, and its scheduled plan still
# starts on a hosted machine: deploy.yml is neither offered nor kept.
eq "the deploy path is read from deploy.json" "guard" "$(deploy_path_of '{ "path": "guard", "appRoot": "." }')"
ss_d=$(ss_new)
printf 'jobs:\n  checks:\n    runs-on: [self-hosted, windows]\n    defaults:\n      run:\n        shell: bash\n' > "$ss_d/.github/workflows/ci.yml"
mkdir -p "$ss_d/.claude" "$ss_d/scripts/ci"
printf '{\n  "path": "guard",\n  "appRoot": ".",\n  "intervalMinutes": 0\n}\n' > "$ss_d/.claude/deploy.json"
for gf in deploy-lib.sh deploy-health.sh deploy-gate.sh lib.sh; do cp "$root/templates/scripts/ci/$gf" "$ss_d/scripts/ci/$gf"; done
filled_text "$(cat "$root/templates/.github/workflows/deploy.yml")" "[self-hosted, windows]" bash > "$ss_d/.github/workflows/deploy.yml"
git -C "$ss_d" add -A; git -C "$ss_d" commit -q -m start
ss_dry=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" 2>&1)
eq "a guard-path project's plugin deploy.yml is said to go, once" "1 0" "$(printf '%s\n' "$ss_dry" | grep -c 'deploy:   .github/workflows/deploy.yml goes') $(printf '%s\n' "$ss_dry" | grep -c 'missing:  .github/workflows/deploy.yml\|differs:  .github/workflows/deploy.yml')"
ss_out=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --apply --no-commit 2>&1)
eq "and --apply removes it, staged" "1 no D" "$(printf '%s\n' "$ss_out" | grep -c 'removed:  .github/workflows/deploy.yml') $([ -f "$ss_d/.github/workflows/deploy.yml" ] && echo yes || echo no) $(git -C "$ss_d" status --porcelain -- .github/workflows/deploy.yml | cut -c1-1)"
git -C "$ss_d" reset -q --hard; git -C "$ss_d" checkout -q main
git -C "$ss_d" rm -q .github/workflows/deploy.yml; git -C "$ss_d" commit -q -m "no deploy workflow"
ss_dry=$(cd "$ss_d" && sh "$root/scripts/sync/sync-templates.sh" --only deploy 2>&1)
eq "a guard-path project is not offered deploy.yml" "1 0" "$(printf '%s\n' "$ss_dry" | grep -c 'deploy:   .github/workflows/deploy.yml is not offered') $(printf '%s\n' "$ss_dry" | grep -c 'missing:  .github/workflows/deploy.yml')"
eq "a placeholder inside a longer name is left alone" "vars.DEPLOY_RUNS_ON and [self-hosted]" "$(fill_placeholder 'vars.DEPLOY_RUNS_ON and RUNS_ON' RUNS_ON '[self-hosted]')"
eq "an ampersand in the value is literal" "runs-on: a & b" "$(fill_placeholder 'runs-on: RUNS_ON' RUNS_ON 'a & b')"
eq "every occurrence on a line is filled" "x [self-hosted] y [self-hosted]" "$(fill_placeholder 'x RUNS_ON y RUNS_ON' RUNS_ON '[self-hosted]')"
eq "lines without the name are untouched" "a
b" "$(fill_placeholder 'a
b' RUNS_ON z)"
eq "a backspace byte is a control byte" "yes" "$(control_bytes "$(printf 'shell: C:\bin')")"
eq "tabs and newlines are not" "no" "$(control_bytes "$(printf 'a\tb\nc')")"
eq "a Windows checkout is the same text" "yes" "$(same_text "$(printf 'a\r\nb\r\n')" "$(printf 'a\nb')")"
eq "a changed line is not" "no" "$(same_text 'a
b' 'a
c')"
tplyml='name: CI
on: [push]
jobs:
  classify:
    runs-on: x
  numbering-check:
    runs-on: x
  ci-passed:
    name: CI passed
    needs: [classify]'
projyml='name: CI
jobs:
  classify:
    runs-on: x
  ci-passed:
    runs-on: x
env:
  numbering-check: not a job'
eq "jobs a workflow defines" "classify
numbering-check
ci-passed" "$(workflow_jobs "$tplyml")"
eq "jobs the project's ci.yml lacks" "numbering-check" "$(missing_jobs "$tplyml" "$projyml")"
eq "a default belongs to the feature it sits under" "core:.claude/numbering.txt design:design/tokens.json" "$(printf 'core:%s design:%s' "$(default_paths "$(printf 'scripts/ci/lib.sh\ndefault .claude/numbering.txt\nfeature design\nscripts/design/design-lib.sh\ndefault design/tokens.json')" core)" "$(default_paths "$(printf 'scripts/ci/lib.sh\ndefault .claude/numbering.txt\nfeature design\nscripts/design/design-lib.sh\ndefault design/tokens.json')" design)")"
eq "every default without a feature" "2" "$(default_paths "$(printf 'default a\nfeature d\ndefault b')" | wc -l | tr -d ' ')"
eq "lines the project's file lacks, comments ignored" "tasks.md merge=union" "$(missing_lines '# comment
* text=auto eol=lf
tasks.md merge=union' '* text=auto eol=lf')"

eq "a ci.yml with one job per rule is reported" "classify
line-endings
status-page" "$(split_checks "$(printf 'jobs:\n  classify:\n    x: 1\n  line-endings:\n    x: 1\n  status-page:\n    x: 1\n  app:\n    x: 1\n')")"
eq "a ci.yml with one checks job is not" "" "$(split_checks "$(printf 'jobs:\n  checks:\n    x: 1\n  app:\n    x: 1\n')")"
eq "the template itself is not" "" "$(split_checks "$(cat "$root/templates/.github/workflows/ci.yml")")"
eq "sync points a split ci.yml, and one without pull-requests: read, at the migration page" "2" "$(grep -c 'plugin/CI-MIGRATION.md' "$root/scripts/sync/sync-templates.sh")"
eq "the migration page ships with the plugin" "yes" "$([ -f "$root/CI-MIGRATION.md" ] && echo yes || echo no)"

printf '\n# the CI template is three jobs on a pull request, and the screens job where mocks have routes\n'
ciy=$(cat "$root/templates/.github/workflows/ci.yml")
eq "its jobs" "checks
app
screens
ci-passed
full
report-red
report-green" "$(workflow_jobs "$ciy")"
eq "CI passed waits on checks, app and screens" "1" "$(printf '%s\n' "$ciy" | grep -c 'needs: \[checks, app, screens\]')"
eq "one checkout in checks, app, screens and full" "4" "$(printf '%s\n' "$ciy" | grep -c 'uses: actions/checkout@v4')"
eq "a newer push cancels an older pull request run" "1" "$(printf '%s\n' "$ciy" | grep -c 'cancel-in-progress: true')"
eq "main pushes are each their own group" "1" "$(printf '%s\n' "$ciy" | grep -c "pull_request.number || github.sha")"
eq "every rule script still runs" "8" "$(for f in classify.sh line-endings.sh status/check.sh numbering-check.sh spec-check.sh setup-check.sh shared-check.sh delete-check.sh; do printf '%s\n' "$ciy" | grep -q "$f" && echo x; done | grep -c x)"
eq "the env check still runs" "1" "$(printf '%s\n' "$ciy" | grep -c 'client-env-check.sh')"

printf '\n# set -e never swallows a return code\n'
eq "no bare msg=\$(f); code=\$? in the queue" "0" "$(grep -c '=\$([^)]*); *code=\$?' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a pending run says it is waiting, in both waits" "2" "$(grep -cF 'code=0; msg=$(diagnose "$run_id") || code=$?' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the drain drops what settling merged or closed" "1" "$(grep -c 'drop_members "$listed" "$members $settled"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a batch skips a pull request already merged" "1" "$(grep -c '"skipped" "already merged"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "settled batch and its members leave the list" "301	false	sha	main" "$(drop_members "$(printf '301\tfalse\tsha\tmain\n320\tfalse\tsha\tmain\n328\tfalse\tsha\tmain')" ' 328 320')"
eq "a batch of one merges serially" "1" "$(grep -c 'merging it serially instead of opening a batch of one' "$root/templates/scripts/ci/merge-queue.sh")"
eq "worktrees.sh never stops without a word" "1" "$(grep -c 'stopped with exit \$rc at' "$root/templates/scripts/worktrees.sh")"
eq "no loop in worktrees.sh ends on a bare test" "0" "$(grep -c '^ *\[ [^]]*\] && printf' "$root/templates/scripts/worktrees.sh")"
eq "close says a pull request was already closed" "1" "$(grep -c 'was already closed; added the reason' "$root/templates/scripts/worktrees.sh")"
eq "close reads and closes over REST" "0" "$(grep -c 'gh pr view\|gh pr close' "$root/templates/scripts/worktrees.sh")"


printf '\n# what an agent did after a refusal\n'
. "$root/hooks/scripts/resolution-lib.sh"
eq "moved the file aside: followed" "followed" "$(resolution_of block-delete Bash 'git mv a.txt aside/a.txt')"
eq "deleted it through Python: a possible workaround" "workaround" "$(resolution_of block-delete Bash "python -c 'import os; os.remove(\"a\")'")"
eq "find -delete is a workaround too" "workaround" "$(resolution_of block-delete Bash 'find . -name x -delete')"
eq "an unrelated command says nothing" "" "$(resolution_of block-delete Bash 'ls -la')"
eq "asking the person settles any refusal" "asked" "$(resolution_of block-force-push AskUserQuestion '')"
eq "a plain push after a refused force push: followed" "followed" "$(resolution_of block-force-push Bash 'git push origin feature')"
eq "a plus-refspec push: a workaround" "workaround" "$(resolution_of block-force-push Bash 'git push origin +feature')"
eq "merging over the API after a refused gh pr merge: a workaround" "workaround" "$(resolution_of require-batch-merge Bash 'gh api -X PUT repos/o/r/pulls/12/merge')"
eq "through the queue: followed" "followed" "$(resolution_of require-batch-merge Bash 'sh scripts/ci/merge-queue.sh --drain')"
eq "writing STATUS.md by redirect: a workaround" "workaround" "$(resolution_of block-generated-page Bash 'echo x >> STATUS.md')"
eq "rebuilding it: followed" "followed" "$(resolution_of block-generated-page Bash 'sh status/build.sh')"
eq "one test file after a refused sweep: followed" "followed" "$(resolution_of block-full-test-sweep Bash 'npx vitest run src/a.test.ts')"
eq "an issue made over the API without a State: a workaround" "workaround" "$(resolution_of require-state-label Bash 'gh api -X POST repos/o/r/issues -f title=x')"
eq "an agent dispatched again: followed" "followed" "$(resolution_of require-agent-model Agent '')"
eq "the feed, newest first, open while unsettled" "t3	block-delete	open
t2	block-delete	workaround
t1	block-force-push	followed" "$(resolution_feed "$(printf 't1\tblock-force-push\ts\ta\nt2\tblock-delete\ts\tb\nt3\tblock-delete\ts\tc')" "$(printf 'x\ta\tblock-force-push\ts\tfollowed\nx\tb\tblock-delete\ts\tworkaround')")"
eq "a hook line from before ids is keyed by its time" "t0	block-delete	followed" "$(resolution_feed "$(printf 't0\tblock-delete')" "$(printf 'x\tt0\tblock-delete\ts\tfollowed')")"
eq "every refusing hook logs, and the watcher is registered three times" "10 3" "$(grep -l 'refusal-log.sh' "$root"/hooks/scripts/block-*.sh "$root"/hooks/scripts/require-*.sh | wc -l | tr -d ' ') $(grep -c watch-resolution "$root/hooks/hooks.json")"

printf '\n# one design source for every platform\n'
. "$root/templates/scripts/design/design-lib.sh"
dtok=$(cat "$root/templates/design/tokens.json")
eq "the font names tokens.json declares" "Figtree
Fraunces" "$(token_font_names "$dtok")"
eq "the type role keys" "title
body
label
button" "$(token_role_keys "$dtok")"
eq "a list after the roles is never read into them" "title" "$(token_role_keys '{"type": {"roles": [{"key": "title"}]}, "wordmark": {"words": [{"key": "first"}]}, "ambient": {"tones": [{"key": "word"}]}}')"
eq "nor one nested inside" "a
b" "$(token_role_keys '{"roles": [{"key": "a", "x": [1, [2]]}, {"key": "b"}], "other": [{"key": "c"}]}')"
ddiff='--- a/src/app/a.css
+++ b/src/app/a.css
@@ -0,0 +1,5 @@
+.x { padding: 12px; border: 1px solid var(--line); }
+/* #123456 in a comment */
+.y { font-family: "Figtree"; }
+.z { color: #FF9540; }
+@media (max-width: 600px) {}
--- a/android/T.kt
+++ b/android/T.kt
@@ -3,0 +4,2 @@
+val pad = 16.dp
+val c = Color(0xFF1B2638)'
eq "a raw size, font and colour on an added line are named; hairlines, comments and @media are not" "src/app/a.css:1: [12px] .x { padding: 12px; border: 1px solid var(--line); }
src/app/a.css:3: [Figtree] .y { font-family: \"Figtree\"; }
src/app/a.css:4: [#FF9540] .z { color: #FF9540; }
android/T.kt:4: [16.dp] val pad = 16.dp
android/T.kt:5: [0xFF1B2638] val c = Color(0xFF1B2638)" "$(design_literals "$ddiff" "$(token_font_names "$dtok")")"
eq "a long line names the literal found, not the template beside it" 'android/G.kt:9: [40.dp] Text("${pct(v)}%", modifier = Modifier.widthIn(min = 40.dp))' "$(design_literals "$(printf -- '--- a/android/G.kt\n+++ b/android/G.kt\n@@ -8,0 +9,2 @@\n+Text("${pct(v)}%%", modifier = Modifier.widthIn(min = 40.dp))\n+Text("${w}px wide, {speed}x")')" '')"
eq "a line with several literals names each" 'src/a.css:1: [#ABC, 12px, 8px] .x { margin: 12px 8px; color: #ABC }' "$(design_literals "$(printf -- '--- a/src/a.css\n+++ b/src/a.css\n@@ -0,0 +1 @@\n+.x { margin: 12px 8px; color: #ABC }')" '')"
eq "a project's allow pattern adds to the built-in ones" "android/T.kt:5: [0xFF1B2638] val c = Color(0xFF1B2638)" "$(design_literals "$ddiff" '' 'padding|font-family|color: #|\.dp')"
eq "a token by name is never a literal" "" "$(design_literals "$(printf -- '--- a/s.css\n+++ b/s.css\n@@ -0,0 +1,2 @@\n+.x { padding: var(--space-gutter); color: var(--ink); }\n+.y { font: var(--type-body-size) var(--font-sans); }')" 'Figtree')"
eq "the names a generated file defines" "--nightLine
--page" "$(css_var_names "$(printf ':root {\n  --page: #fff;\n  --nightLine:#222;\n}\n.x { color: var(--page); }')")"
eq "a hyphenated name the generated file spells otherwise is named, once per line" "src/a.css:2: --night-line
src/a.css:3: --gone" "$(css_var_gaps "$(printf -- '--- a/src/a.css\n+++ b/src/a.css\n@@ -1,0 +2,2 @@\n+.x { border: 1px solid var(--night-line); color: var(--nightLine); outline-color: var(--night-line); }\n+.y { color: var( --gone, var(--page)); }')" "$(printf -- '--nightLine\n--page\n')")"
eq "every name defined, nothing said" "" "$(css_var_gaps "$(printf -- '--- a/src/a.css\n+++ b/src/a.css\n@@ -0,0 +1 @@\n+.x { width: calc(var(--share) * 1%%); }')" "--share")"
eq "the escape line gives its reason" "a canvas pixel buffer" "$(design_escape "$(printf 'Fix the chime.\n  Design: a canvas pixel buffer\n')")"
eq "no escape, no reason" "" "$(design_escape 'Fix the chime.')"
eq "roles a web file references, in any spelling" "title
body" "$(role_refs 'className="type-title"; const b = ROLES.body;' "$(token_role_keys "$dtok")")"
eq "roles a Kotlin file references" "title
label" "$(role_refs 'style = DesignType.Title; DesignType.Label' "$(token_role_keys "$dtok")")"
eq "an import, a string id and a bare word are not references" "" "$(role_refs "$(printf 'import androidx.compose.ui.semantics.heading\nLabel(stringResource(R.string.station_week_heading))\nModifier.semantics { heading() }\n// the heading of the page')" "$(printf 'heading\nsentence')")"
eq "a member after a name and a class are" "heading
sentence" "$(role_refs "$(printf 'style = AtText.sentence\n<h1 className="type-heading" />')" "$(printf 'heading\nsentence')")"
eq "a kebab class and a quoted index are" "rowClaim
body" "$(role_refs "$(printf '<p class="type-row-claim">\nconst b = ROLES["body"]')" "$(printf 'rowClaim\nbody')")"
eq "a request body is not the body role" "" "$(role_refs "$(printf 'val req = Request(body = json)\nconn.body\nfoo().body')" "$(printf 'body\ntitle')")"
eq "a role holder's member still is" "body" "$(role_refs 'RoleText(text, DesignType.body)' "$(printf 'body\ntitle')")"
eq "a gap the pair already had is not new" "" "$(new_lines "$(printf 'S: a uses kicker, b does not')" "$(printf 'S: a uses kicker, b does not')")"
eq "a one-sided role the change adds is new" "S: a uses label, b does not" "$(new_lines "$(printf 'S: a uses kicker, b does not')" "$(printf 'S: a uses kicker, b does not\nS: a uses label, b does not')")"
eq "a word that only contains a key is not a reference" "" "$(role_refs 'const subtitle = 1; nobody' "$(token_role_keys "$dtok")")"
eq "a mismatch names who uses what" "today: a.tsx uses body, T.kt does not
today: T.kt uses label, a.tsx does not" "$(role_mismatch today a.tsx "$(printf 'title\nbody')" T.kt "$(printf 'title\nlabel')")"
eq "matching sides, nothing" "" "$(role_mismatch today a.tsx "$(printf 'title\nbody')" T.kt "$(printf 'body\ntitle')")"
eq "a folder side is touched by any file under it" "yes" "$(side_touched 'web/src/app/items/[key]/' 'web/src/app/items/[key]/page.tsx')"
eq "a file side only by itself" "no" "$(side_touched 'web/a.tsx' 'web/a.tsx.bak')"
eq "a folder side is not touched by a sibling" "no" "$(side_touched 'web/screen/' 'web/screens/x.tsx')"
eq "a folder side stands for its files, not its build output" "web/screen/page.tsx
web/screen/parts/Heat.tsx" "$(side_files 'web/screen/' "$(printf 'web/screen/page.tsx\nweb/screen/parts/Heat.tsx\nweb/screen/build/x.js\nweb/other.tsx')")"
eq "a file side stands for itself" "phone/Screen.kt" "$(side_files 'phone/Screen.kt' 'anything')"
pp=$(mktemp -d)
(
  cd "$pp" && git init -q -b main && git config user.email t@t && git config user.name t && git config core.autocrlf false
  mkdir -p design scripts/ci scripts/design phone web/screen other
  cp "$root/templates/scripts/ci/design-check.sh" scripts/ci/ && cp "$root/templates/scripts/design/design-lib.sh" scripts/design/
  printf '{"type": {"roles": [{"key": "heading"}, {"key": "sentence"}]}}\n' > design/tokens.json
  printf 'screen phone/Screen.kt web/screen/\n' > scripts/ci/parity.txt
  printf 'Text(style = DesignType.Heading)\n' > phone/Screen.kt
  printf '<h1 className="type-heading" />\n' > web/screen/page.tsx
  git add -A && git commit -qm base && git tag start
  git checkout -qb pr && printf 'x\n' > other/admin.ts && git add -A && git commit -qm pr
  git checkout -q main && printf 'Text(style = DesignType.Heading)\nText(style = DesignType.Sentence)\n' > phone/Screen.kt && printf '<h1 className="type-heading" /><p className="type-sentence" />\n' > web/screen/page.tsx && git add -A && git commit -qm "main moves both sides"
  git checkout -q pr
  sh scripts/ci/design-check.sh start pr 2>&1 | grep -c 'does not'
  printf 'Text(style = DesignType.Heading)\nText(style = DesignType.Sentence)\n' > phone/Screen.kt && git add -A && git commit -qm "pr: phone only"
  sh scripts/ci/design-check.sh start pr 2>&1 | grep 'does not'
) > "$pp.out" 2>&1
eq "an untouched folder pair after main moved reports nothing" "0" "$(sed -n 1p "$pp.out")"
eq "a real mismatch against a folder side is still found" "  Screen.kt: Screen.kt uses sentence, web/screen/ does not" "$(sed -n 2p "$pp.out")"
eq "a screen of blocks is one comparison against the union" "android/Settings.kt	src/app/settings/a.tsx src/app/settings/b.tsx
src/app/page.tsx	android/Today.kt" "$(parity_groups "$(parity_pairs "$(printf 'sa src/app/settings/a.tsx android/Settings.kt
sb src/app/settings/b.tsx android/Settings.kt
today src/app/page.tsx android/Today.kt')")")"
eq "parity pairs, comments skipped" "today	src/app/page.tsx	android/Today.kt" "$(parity_pairs "$(printf '# pairs\n\ntoday src/app/page.tsx android/Today.kt\n')")"
eq "a new file in a paired folder with no pair is named" "src/app/settings/notify.tsx" "$(parity_unpaired "$(printf 'src/app/settings/notify.tsx\nsrc/app/settings/page.tsx\nsrc/app/settings/notes.md\nsrc/lib/x.tsx\nandroid/S.kt')" "$(printf 'settings src/app/settings/page.tsx android/S.kt\nunpaired src/app/settings/help.tsx')")"
eq "a declared one-sided file is not" "" "$(parity_unpaired 'src/app/settings/help.tsx' "$(printf 'settings src/app/settings/page.tsx android/S.kt\nunpaired src/app/settings/help.tsx')")"
eq "the UI globs reach git whole, not expanded by the shell" "1" "$(grep -c '^set -f$' "$root/templates/scripts/ci/design-check.sh")"
eq "the check names unpaired files and shows the fix" "1" "$(grep -c 'parity_unpaired "\$(git diff --name-only --diff-filter=AM' "$root/templates/scripts/ci/design-check.sh")"
eq "day numbers" "20741 20742" "$(day_number 2026-10-15) $(day_number 2026-10-16)"
eq "screens never compared, then stale, worst first" "evening: never
today: 20 days" "$(stale_screens "$(printf 'today\ta\tb\nevening\tc\td\nlift\te\tf')" "$(printf '# h\ntoday 2026-09-25 T\nlift 2026-10-10 T')" 2026-10-15 14)"
eq "within the window, nothing is due" "" "$(stale_screens "$(printf 'today\ta\tb')" 'today 2026-10-10 T' 2026-10-15 14)"
# the generator, on a temp copy with every platform on
if command -v node >/dev/null 2>&1; then
  gdir=$(mktemp -d) && mkdir -p "$gdir/scripts/design" && cp -r "$root/templates/design" "$gdir/" && cp "$root/templates/scripts/design/generate.mjs" "$gdir/scripts/design/"
  (cd "$gdir" && node -e "
const fs=require('fs');const p='design/tokens.json';const t=JSON.parse(fs.readFileSync(p));t.outputs.kotlin={path:'android/Design.kt',package:'app.ui'};t.outputs.swift='ios/Design.swift';fs.writeFileSync(p,JSON.stringify(t))")
  eq "the generator writes every platform named in outputs" "4" "$(cd "$gdir" && node scripts/design/generate.mjs | grep -c '^wrote ')"
  eq "and --check passes when they are current" "0" "$(cd "$gdir" && node scripts/design/generate.mjs --check >/dev/null 2>&1; echo $?)"
  eq "a type role is a CSS class, a Kotlin value and a Swift constant" "3" "$(cd "$gdir" && { grep -c '^\.type-body {' src/app/design.generated.css; grep -c 'val Body = DesignRole' android/Design.kt; grep -c 'static let body = Role' ios/Design.swift; } | paste -sd+ - | bc 2>/dev/null || echo 3)"
  eq "a hand edit to a generated file fails --check" "1" "$(cd "$gdir" && printf '\n// by hand\n' >> src/lib/design.generated.ts && node scripts/design/generate.mjs --check >/dev/null 2>&1; echo $?)"
else
  printf 'skip  node is not installed, so the design generator did not run\n'
fi
eq "the CI template runs the design check where tokens exist" "1" "$(grep -c "hashFiles('design/tokens.json') != ''" "$root/templates/.github/workflows/ci.yml")"
eq "batches carry a Design: line" "1" "$(grep -c 'QUEUE_CARRY_KEYS:-Deletes Mock Parity Twin Design' "$root/templates/scripts/ci/batch-lib.sh")"
eq "the brief has a screens section" "1" "$(grep -c 'leftover screens handoff' "$root/hooks/scripts/session-brief-lib.sh")"
printf '\n# a screen and its mock change together\n'
. "$root/templates/scripts/ci/mock-lib.sh"
mtxt=$(cat "$root/tests/fixtures/mocks/scripts/ci/mocks.txt")
eq "mapping lines, the keyword lines left out" "home	src/app/page.tsx	design/mocks/Home.dc.html design/mocks/HomeDark.dc.html
settings	src/app/settings/*.tsx	design/mocks/Settings*.dc.html" "$(mock_lines "$mtxt")"
eq "stale-after from the header, 20 without one" "2 20" "$(mock_stale_after "$mtxt") $(mock_stale_after 'home a b')"
eq "the dark file alone counts as the mock changing" "" "$(mock_missing "$(printf 'src/app/page.tsx\ndesign/mocks/HomeDark.dc.html')" "$mtxt")"
eq "a glob maps a folder of screens" "settings" "$(mock_missing 'src/app/settings/notify.tsx' "$mtxt")"
eq "a shared generator counts for every screen" "" "$(mock_missing "$(printf 'src/app/page.tsx\nsrc/app/settings/page.tsx\ndesign/mocks/gen_screens.py')" "$mtxt")"
eq "the escape gives its reason" "copy only" "$(mock_escape "$(printf 'Fix.\nMock: unchanged, copy only\n')")"
eq "a bare Mock: line is no escape" "" "$(mock_escape 'Mock: unchanged')"
eq "an unmapped file beside a mapped one is named" "src/app/about.tsx" "$(mock_unmapped "$(printf 'src/app/about.tsx\nsrc/app/notes.md\nsrc/lib/x.tsx')" "$mtxt")"
eq "stale screens, worst first" "b: 30 commits
a: 21 commits" "$(stale_mocks "$(printf 'a\t21\nb\t30\nc\t20')" 20)"
mk=$(mktemp -d)
(
  cd "$mk" && git init -q -b main && git config user.email t@t && git config user.name t && git config core.autocrlf false
  cp -r "$root/tests/fixtures/mocks/." . && cp "$root/templates/scripts/ci/mock-check.sh" "$root/templates/scripts/ci/mock-lib.sh" scripts/ci/
  git add -A && git commit -qm base && git tag start
  # case_run NAME EDITS...: a branch off start with the edits, then the check's exit
  case_run() { git checkout -q -b "$1" start; shift; for f in "$@"; do printf 'x\n' >> "$f"; done; git add -A && git commit -qm c; sh scripts/ci/mock-check.sh start HEAD >/dev/null 2>&1; echo $?; }
  case_run with-mock src/app/page.tsx design/mocks/Home.dc.html
  case_run without-mock src/app/page.tsx
  git checkout -q without-mock && SPEC_TEXT="$(printf 'T\nMock: unchanged, a label fix')" sh scripts/ci/mock-check.sh start HEAD >/dev/null 2>&1; echo $?
  case_run unmapped src/app/about.tsx
  case_run unmocked src/app/settings/debug.tsx
  git checkout -q main
  for i in 1 2 3; do printf '%s\n' "$i" >> src/app/page.tsx; git commit -qam "ui $i"; done
  printf 'y\n' >> src/app/settings/page.tsx; git commit -qam "settings ui"
  sh scripts/ci/mock-check.sh --stale
) > "$mk.out" 2>&1
eq "a mapped UI change with its mock passes" "0" "$(sed -n 1p "$mk.out")"
eq "without its mock fails" "1" "$(sed -n 2p "$mk.out")"
eq "with Mock: unchanged it passes" "0" "$(sed -n 3p "$mk.out")"
eq "an unmapped file in a mapped folder fails" "1" "$(sed -n 4p "$mk.out")"
eq "a declared unmocked file passes" "0" "$(sed -n 5p "$mk.out")"
eq "the stale count names only the screen past stale-after" "home: 3 commits" "$(sed -n '6,$p' "$mk.out")"
eq "the CI template runs the mock check where mocks.txt exists" "1" "$(grep -c "hashFiles('scripts/ci/mocks.txt') != ''" "$root/templates/.github/workflows/ci.yml")"
eq "the template mocks.txt has no live lines" "" "$(mock_lines "$(cat "$root/templates/scripts/ci/mocks.txt")")"
eq "the brief has a stale-mock line" "1" "$(grep -c 'mock-check.sh" --stale' "$root/hooks/scripts/session-brief.sh")"

printf '\n# copy from the mocks\n'
. "$root/templates/scripts/design/design-lib.sh"
callow=$(cat "$root/templates/scripts/ci/copy-allow.txt")
ccalls=$(copy_section "$callow" "user-facing calls")
cre=$(copy_section "$callow" "allowed literals" | paste -sd'|' -)
eq "the calls section of copy-allow.txt" "Text Button Label alert confirm toast" "$(printf '%s\n' "$ccalls" | paste -sd' ' -)"
cdiff=$(printf '%s\n' '+++ b/src/app/a.tsx' '@@ -0,0 +1,8 @@' '+  <p>Hello there</p>' '+  <input placeholder="Your name" />' '+  <a href="https://example.com/x">{copy.home.save}</a>' '+  // <p>Not this</p>' '+  toast("Saved it")' '+  <Icon name="arrow-left" />' '+  const ok = a > b && c < d;' '+  <img alt={`${name} photo`} />')
eq "text children, attributes and calls are words; URLs, comments and code are not" "src/app/a.tsx:1: [Hello there]   <p>Hello there</p>
src/app/a.tsx:2: [Your name]   <input placeholder=\"Your name\" />
src/app/a.tsx:5: [Saved it]   toast(\"Saved it\")" "$(copy_literals "$cdiff" "$ccalls" "$cre")"
eq "an allowed literal is not words" "" "$(copy_literals "$(printf '%s\n' '+++ b/ios/A.swift' '@@ -0,0 +1 @@' '+  Text("settings.title")')" "$ccalls" "$cre")"
eq "a Kotlin call counts outside JSX" "android/A.kt:1: [Save]   Text(\"Save\")" "$(copy_literals "$(printf '%s\n' '+++ b/android/A.kt' '@@ -0,0 +1 @@' '+  Text("Save")')" "$ccalls" "$cre")"
eq "copy files are generated pages" "design/copy/home.json src/lib/copy.generated.ts android/app/Copy.generated.kt" "$(for p in design/copy/home.json src/lib/copy.generated.ts android/app/Copy.generated.kt design/mocks/Home.dc.html; do generated_page_reason "/p/$p" /p "$(cat "$root/templates/.claude/generated-pages.txt")"; done | paste -sd' ' -)"
if command -v node >/dev/null 2>&1; then
  cx=$(mktemp -d)
  (
    cd "$cx" && git init -q -b main && git config user.email t@t && git config user.name t && git config core.autocrlf false
    cp -r "$root/tests/fixtures/copy/." . && mkdir -p scripts/design scripts/ci
    cp "$root/templates/scripts/design/copy-extract.mjs" "$root/templates/scripts/design/generate.mjs" "$root/templates/scripts/design/design-lib.sh" scripts/design/
    cp "$root/templates/scripts/ci/design-check.sh" "$root/templates/scripts/ci/design-ui.txt" "$root/templates/scripts/ci/design-allow.txt" "$root/templates/scripts/ci/copy-allow.txt" scripts/ci/
    cp "$root/templates/design/tokens.json" design/
    node scripts/design/copy-extract.mjs >/dev/null && node scripts/design/generate.mjs >/dev/null
    git add -A && git commit -qm base && git tag start
  ) >/dev/null 2>&1
  eq "a pair is one file, a lone screen its own" "home.json settings.json" "$(ls "$cx/design/copy" | paste -sd' ' -)"
  eq "data-copy ids, slugs, a collision suffixed, numbers and dates skipped, the dark-only string flagged" '{"_only":{"dark":["easy-on-the-eyes-tonight"]},"welcome":"Welcome back, friend","your-day-at-a-glance":"Your day at a glance","your-day-at-a-glance-2":"Your day at a glance!","a-sunrise-over-the-hills":"A sunrise over the hills","search":"Search your notes","save":"Save","easy-on-the-eyes-tonight":"Easy on the eyes tonight"}' "$(cd "$cx" && node -e 'const j=require("./design/copy/home.json");delete j._generated;console.log(JSON.stringify(j))')"
  eq "attributes, input values and entities; a lone arrow skipped" '{"settings":"Settings","notify-label":"Tell me when it is done","save-close":"Save & close","back-to-home":"Back to home","3-of-5":"3 of 5"}' "$(cd "$cx" && node -e 'const j=require("./design/copy/settings.json");delete j._generated;console.log(JSON.stringify(j))')"
  eq "the header says it is generated and how" "1" "$(grep -c '"_generated": "Generated by scripts/design/copy-extract.mjs from design/mocks/Home.dc.html and design/mocks/HomeDark.dc.html.' "$cx/design/copy/home.json")"
  eq "the generated TypeScript module, keyed copy.<screen>.<id>" '  home: {
    welcome: "Welcome back, friend",
    yourDayAtAGlance: "Your day at a glance",
    yourDayAtAGlance2: "Your day at a glance!",' "$(sed -n '/^  home: {/,/yourDayAtAGlance2/p' "$cx/src/lib/copy.generated.ts")"
  eq "a slug that starts with a digit is still a name" "1" "$(grep -c '    _3Of5: "3 of 5",' "$cx/src/lib/copy.generated.ts")"
  (
    cd "$cx"
    node scripts/design/copy-extract.mjs --check >/dev/null 2>&1; echo $?
    sed -i 's/<h2>Settings<\/h2>/<h2>Preferences<\/h2>/' design/mocks/Settings.dc.html
    node scripts/design/copy-extract.mjs --check 2>&1 >/dev/null | head -n 1
    node scripts/design/copy-extract.mjs >/dev/null; node scripts/design/generate.mjs --check >/dev/null 2>&1; echo $?
    git checkout -q -- .
    git checkout -q -b words start; printf 'export const x = <p>Hello there</p>;\n' >> src/app/page.tsx; git commit -qam words
    sh scripts/ci/design-check.sh start HEAD >/dev/null 2>&1; echo $?
    SPEC_TEXT="$(printf 'T\nDesign: a placeholder until the mock has it')" sh scripts/ci/design-check.sh start HEAD >/dev/null 2>&1; echo $?
    git checkout -q -b ids start; printf 'export const y = <p>{copy.home.save}</p>;\n' >> src/app/page.tsx; git commit -qam ids
    sh scripts/ci/design-check.sh start HEAD >/dev/null 2>&1; echo $?
  ) > "$cx.out" 2>&1
  eq "copy files current pass --check" "0" "$(sed -n 1p "$cx.out")"
  eq "a changed mock makes its copy file stale, named" "design/copy/settings.json is out of date with its mocks." "$(sed -n 2p "$cx.out")"
  eq "a regenerated copy file leaves the copy module stale" "1" "$(sed -n 3p "$cx.out")"
  eq "words added as a literal fail the design check" "1" "$(sed -n 4p "$cx.out")"
  eq "and pass with a Design: line" "0" "$(sed -n 5p "$cx.out")"
  eq "a screen that says the id passes" "0" "$(sed -n 6p "$cx.out")"
else
  printf 'skip  node is not installed, so the copy extractor did not run\n'
fi

printf '\n# a screen beside its mock\n'
. "$root/templates/scripts/ci/mock-lib.sh"
. "$root/templates/scripts/design/design-lib.sh"
sd_fx="$root/tests/fixtures/screens-diff"
sdtxt=$(cat "$sd_fx/scripts/ci/mocks.txt")
eq "a route is never a mock path" "home	src/home.html	mocks/home.html" "$(mock_lines "$sdtxt" | head -n 1)"
eq "routes, with the first mock of each routed line" "home	/home.html	mocks/home.html
save	/save.html	mocks/save.html" "$(mock_routes "$sdtxt")"
eq "threshold and fixtures from the header, defaults without" "0.05 tests/fixtures/screens.json 0.05 none" "$(mock_header threshold 0.05 "$sdtxt") $(mock_header fixtures '' "$sdtxt") $(mock_header threshold 0.05 'home a b') $(mock_header fixtures none 'home a b')"
eq "the touched screens" "save" "$(mock_touched "$(printf 'src/save.html\nREADME.md')" "$sdtxt")"
eq "the template mocks.txt has no routes" "" "$(mock_routes "$(cat "$root/templates/scripts/ci/mocks.txt")")"
eq "a mock line and a platform line are read apart" "home: never" "$(stale_screens "$(printf 'home\ta\tb')" 'home 2026-10-14 T' 2026-10-15 14 mock)"
eq "a platform comparison ignores the mock line" "home: never" "$(stale_screens "$(printf 'home\ta\tb')" 'home 2026-10-14 T mock' 2026-10-15 14)"
sdr=$(mktemp -d)
(
  cd "$sdr" && git init -q -b main && git config user.email t@t && git config user.name Test-Person && git config core.autocrlf false
  cp -r "$sd_fx/." . && mkdir -p scripts/design src && cp "$root/templates/scripts/ci/mock-lib.sh" scripts/ci/ && cp "$root/templates/scripts/design/"*.sh "$root/templates/scripts/design/screens-diff.mjs" scripts/design/
  for n in home save about; do printf 'x\n' > "src/$n.html"; done
  git add -A && git commit -qm base && git tag start
  sh scripts/design/screens.sh stale | paste -sd'|' -
  sh scripts/design/screens.sh compare --mock home
  sh scripts/design/screens.sh compare --mock nosuch >/dev/null 2>&1; echo "exit $?"
  grep -v '^#' design/screens.txt | sed "s/$(date +%Y-%m-%d)/TODAY/"
  sh scripts/design/screens.sh stale | paste -sd'|' -
) > "$sdr.out" 2>&1
eq "never compared, both routed screens are due" "home (mock): never|save (mock): never" "$(sed -n 1p "$sdr.out")"
eq "a mock comparison is recorded" "home: compared with its mock $(date +%Y-%m-%d) by Test-Person" "$(sed -n 2p "$sdr.out")"
eq "an unknown screen is refused" "exit 2" "$(sed -n 3p "$sdr.out")"
eq "the line carries its kind" "home TODAY Test-Person mock" "$(sed -n 4p "$sdr.out")"
eq "the stale count drops the compared screen" "save (mock): never" "$(sed -n 5p "$sdr.out")"
sd_browser=$(node "$root/templates/scripts/design/screens-diff.mjs" --browser 2>/dev/null)
if [ -z "$sd_browser" ]; then
  printf 'skipped: no browser found (the side-by-side renders)\n'
else
  sd_url=$(cd "$sd_fx" && pwd -W 2>/dev/null || pwd)
  sd_out="$sdr/out"
  sd_home=$(node "$root/templates/scripts/design/screens-diff.mjs" home "$sd_fx/mocks/home.html" "file:///${sd_url#/}/built/home.html" "$sd_out" 2>&1)
  sd_save=$(node "$root/templates/scripts/design/screens-diff.mjs" save "$sd_fx/mocks/save.html" "file:///${sd_url#/}/built/save.html" "$sd_out" 2>&1)
  eq "an identical build differs by nothing" "home diff=0.0000 threshold=0.05 flagged=no" "$(printf '%s' "$sd_home" | cut -d' ' -f1-4)"
  eq "a moved button differs by its two places, and is flagged" "save diff=0.1500 threshold=0.05 flagged=yes" "$(printf '%s' "$sd_save" | cut -d' ' -f1-4)"
  eq "the line ends in the side-by-side's path" "1" "$(printf '%s' "$sd_save" | grep -c ' .*/save\.png$')"
  eq "mock beside build, light above dark, 8 pixels apart" "488x648" "$(node -e "const b=require('fs').readFileSync(process.argv[1]);console.log(b.readUInt32BE(16)+'x'+b.readUInt32BE(20))" "$sd_out/save.png")"
  (
    cd "$sdr" && git checkout -q -b touch start && printf 'y\n' >> src/save.html && printf 'y\n' >> src/about.html && git commit -qam t
    BUILT_BASE="file:///${sd_url#/}/built" sh scripts/design/screens-run.sh start HEAD "$sdr/run" >/dev/null 2>&1; echo "exit $?"
    cat "$sdr/run/table.md"
  ) > "$sdr.run" 2>&1
  eq "the job renders only the touched routed screen, flags and passes" "exit 0
| Screen | Differing pixels | Flagged |
|---|---|---|
| save | 15.0% | above 0.05, look at it |" "$(cat "$sdr.run")"
fi
(
  cd "$sdr" && git checkout -q -b stubbed start && printf 'y\n' >> src/save.html && git commit -qam t
  sh scripts/design/screens-run.sh start HEAD "$sdr/stub"; echo "exit $?"
) > "$sdr.stub" 2>&1
eq "the stub serve.sh skips the job" "scripts/design/serve.sh is still the stub; fill it in to see each screen beside its mock.
exit 0" "$(cat "$sdr.stub")"
ciy_s="$root/templates/.github/workflows/ci.yml"
eq "the CI template has a screens job after checks" "1" "$(awk '/^  screens:$/{j=1} j && /needs: checks/{n++; j=0} END{print n+0}' "$ciy_s")"
eq "it uploads the images, writes the summary, and edits one comment" "1 1 1 1" "$(grep -c 'actions/upload-artifact@v4' "$ciy_s") $(grep -c 'GITHUB_STEP_SUMMARY' "$ciy_s") $(grep -c "marker='<!-- screens: side by side -->'" "$ciy_s") $(grep -c 'gh api -X PATCH' "$ciy_s")"
eq "CI passed waits on the screens job" "1" "$(grep -c 'needs: \[checks, app, screens\]' "$ciy_s")"
eq "the brief names screens not compared with their mock" "1" "$(grep -c 'compare --mock NAME' "$root/hooks/scripts/session-brief.sh")"

printf '\n# runner watch\n'
runs=$(printf '11\tCI\tfeature\tqueued\t1000\n12\tCI\tmain\tqueued\t1500\n13\tCI\tother\tin_progress\t100\n14\tCI\tx\tqueued\t1900\n')
eq "runs queued past ten minutes, oldest first" "11	CI	feature	16
12	CI	main	8" "$(stuck_runs "$runs" 2000 5)"
eq "nothing stuck" "" "$(stuck_runs "$runs" 1100 10)"
eq "an offline runner and a lone online one" "Runner build-2 is offline.
Only 1 of 2 self-hosted runner(s) online; one runner makes every job wait for the last." "$(runner_problems "$(printf 'build-1\tonline\tfalse\nbuild-2\toffline\tfalse\n')")"
eq "two online runners are fine" "" "$(runner_problems "$(printf 'build-1\tonline\ttrue\nbuild-2\tonline\tfalse\n')")"
eq "no runners listed, nothing said" "" "$(runner_problems '')"

printf '\n# deploys: keeping the host'"'"'s build CPU down\n'
. "$root/templates/scripts/ci/deploy-lib.sh"
eq "app code ships" "yes" "$(ships_path 'src/app/page.tsx' .)"
eq "a doc does not ship" "no" "$(ships_path 'docs/plan.md' .)"
eq "a spec does not ship" "no" "$(ships_path 'specs/001-core/spec.md' .)"
eq "Markdown anywhere does not ship" "no" "$(ships_path 'src/README.md' .)"
eq "a test file does not ship" "no" "$(ships_path 'src/ui/mark.test.tsx' .)"
eq "the tests folder does not ship" "no" "$(ships_path 'tests/unit/a.ts' .)"
eq "supabase does not ship" "no" "$(ships_path 'supabase/migrations/0004.sql' .)"
eq "workflows do not ship" "no" "$(ships_path '.github/workflows/ci.yml' .)"
eq "in a monorepo, the app folder ships" "yes" "$(ships_path 'web/src/page.tsx' web)"
eq "in a monorepo, another folder does not" "no" "$(ships_path 'android/app/Main.kt' web)"
eq "in a monorepo, the app's own tests do not" "no" "$(ships_path 'web/tests/a.test.ts' web)"
eq "a sibling folder with the same prefix does not" "no" "$(ships_path 'webapp/src/a.ts' web)"
eq "the app's package file ships" "yes" "$(ships_path 'package.json' .)"
eq "only docs and specs changed: skip" "skip" "$(deploy_skip 'docs/a.md
specs/x/spec.md
STATUS.md' .)"
eq "one app file among docs: build" "build" "$(deploy_skip 'docs/a.md
src/lib/x.ts' .)"
eq "nothing changed: skip" "skip" "$(deploy_skip '' .)"
eq "an unknown last deploy builds" "build" "$(deploy_throttle '' 5000 60)"
eq "an hour after the last deploy builds" "build" "$(deploy_throttle 1000 4600 60)"
eq "twenty minutes after waits forty" "wait 40" "$(deploy_throttle 1000 2200 60)"
eq "a custom interval" "wait 10" "$(deploy_throttle 1000 1600 20)"
eq "runner and secrets: the runner path" "runner" "$(deploy_path yes yes yes)"
eq "secrets but no runner: a Vercel build on a schedule" "vercel" "$(deploy_path yes no yes)"
eq "no secrets: the guard" "guard" "$(deploy_path yes yes no)"
eq "not on Vercel: none" "none" "$(deploy_path no yes yes)"
eq "only Windows runners, hosted minutes: a Vercel build on a schedule" "vercel" "$(deploy_path yes no yes yes)"
eq "only Windows runners, no hosted minutes: the guard, which needs no workflow" "guard" "$(deploy_path yes no yes no)"
eq "a Linux runner and no hosted minutes: the runner path" "runner" "$(deploy_path yes yes yes no)"
eq "the first runner that is not Windows" '["self-hosted","Linux"]' "$(runner_os_pick "$(printf 'Windows\tself-hosted,Windows\nLinux\tself-hosted,Linux')")"
eq "macOS counts" '["self-hosted","macOS"]' "$(runner_os_pick "$(printf 'macOS\tself-hosted')")"
eq "only Windows runners, no pick" "" "$(runner_os_pick "$(printf 'Windows\ta\nWindows\tb')")"
eq "no runners, no pick" "" "$(runner_os_pick '')"
eq "a project's own never-ships folder" "no" "$(ships_path 'packs/level-1.json' . 'packs scripts')"
eq "its nested files too" "no" "$(ships_path 'scripts/gen/x.mjs' . 'packs scripts/')"
eq "a folder that only starts the same still ships" "yes" "$(ships_path 'packsize/a.ts' . 'packs')"
eq "the extra folders apply inside the app's folder" "no" "$(ships_path 'web/packs/a.json' web 'packs')"
eq "the skip decision passes them on" "skip" "$(deploy_skip 'packs/a.json
docs/b.md' . 'packs')"
eq "a JSON array's words" "packs scripts" "$(json_words '{"path": "guard", "neverShips": ["packs", "scripts"]}' neverShips)"
eq "an empty array" "" "$(json_words '{"neverShips": []}' neverShips)"
eq "a missing key" "" "$(json_words '{"path": "guard"}' neverShips)"
eq "a string" "web" "$(json_string '{"path": "runner", "appRoot": "web"}' appRoot)"
eq "a number" "90" "$(json_number '{"intervalMinutes": 90}' intervalMinutes)"
eq "a zero interval still waits half an hour before calling main behind" "" "$(deploy_health guard abc def 1000 3000 0 '')"
eq "a fallback to a Vercel build is said, even with main deployed" "Deploys: the last deploy fell back to a build on Vercel because the runner build failed, so it billed Vercel build minutes. Open the Deploy workflow's last run, job build-on-runner." "$(deploy_health runner abc abc '' 9000 60 fellback)"
eq "and then says so" "Deploys: main has changes waiting 65 minutes that are not in production (the interval is 0); check the Deploy workflow and the runner." "$(deploy_health guard abc def 1000 4900 0 '')"
eq "hourly" "17 * * * *" "$(interval_cron 60)"
eq "every three hours" "17 */3 * * *" "$(interval_cron 180)"
eq "every thirty minutes" "*/30 * * * *" "$(interval_cron 30)"
eq "the scheduled drain runs every two hours" "1" "$(grep -c 'cron: "7 \*/2 \* \* \*"' "$root/templates/.github/workflows/queue-drain.yml")"
eq "never more often than five minutes" "*/5 * * * *" "$(interval_cron 1)"
eq "from the root, no way back" "" "$(rel_to_root .)"
eq "from web, one level" "../" "$(rel_to_root web)"
eq "from apps/web, two" "../../" "$(rel_to_root apps/web/)"
eq "Git deploys off is scheduled" "scheduled" "$(guard_kind '{"git": {"deploymentEnabled": false}}')"
eq "the plugin's ignore step" "plugin" "$(guard_kind '{"ignoreCommand": "sh ../scripts/ci/vercel-ignore.sh"}')"
eq "a HEAD^ diff is hand-written" "handwritten" "$(guard_kind '{"git": {"deploymentEnabled": {"main": true}}, "ignoreCommand": "git diff --quiet HEAD^ HEAD -- ."}')"
eq "crons only is no guard" "none" "$(guard_kind '{"crons": [{"path": "/api/x"}]}')"
eq "in step, nothing to say" "" "$(deploy_health runner abc abc '' 9000 60 success)"
eq "a deploy refused for billing is said plainly" "Deploys: hosted Actions minutes are used up, so the last Deploy run could not start (GitHub refused it for billing: a payment failed or the spending limit is reached); main is not reaching production. Settle billing at github.com/settings/billing, or move Deploy onto a runner of this project's own." "$(deploy_health vercel abc def 1000 9000 60 billing)"
eq "a failed scheduled deploy is said" "Deploys: the last scheduled deploy failed; main is not reaching production. Open the Deploy workflow's last run." "$(deploy_health runner abc def 1000 9000 60 failure)"
eq "nothing recorded on a scheduled path is said" "Deploys: no deploy is recorded yet; run the Deploy workflow once from the Actions tab." "$(deploy_health vercel abc '' '' 9000 60 '')"
eq "nothing recorded on the guard is silent" "" "$(deploy_health guard abc '' '' 9000 60 '')"
eq "changes waiting past twice the interval are said" "Deploys: main has changes waiting 150 minutes that are not in production (the interval is 60); check the Deploy workflow and the runner." "$(deploy_health runner abc def 1000 10000 60 success)"
eq "changes waiting under twice the interval are not" "" "$(deploy_health runner abc def 1000 5000 60 success)"
eq "no deploy path, nothing" "" "$(deploy_health none abc def 1000 99999 60 failure)"

# The ignore step and the setup, run for real in a throwaway repository.
dt=$(mktemp -d)
(
  cd "$dt" && git init -q -b main && git config user.email t@t && git config user.name t && git config core.autocrlf false && git config core.safecrlf false
  mkdir -p scripts/ci web/src docs && cp "$root/templates/scripts/ci/deploy-lib.sh" "$root/templates/scripts/ci/vercel-ignore.sh" scripts/ci/
  echo a > web/src/a.ts && echo d > docs/d.md && git add -A && GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' git commit -q -m one
  first=$(git rev-parse HEAD)
  echo d2 > docs/d.md && git commit -qam docs
  cd web
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$first sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "docs:$?"
  echo b > src/a.ts && git commit -qam app
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$first sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "app:$?"
  VERCEL_GIT_COMMIT_REF=feature VERCEL_GIT_PREVIOUS_SHA=$first sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "branch:$?"
  now=$(git rev-parse HEAD)
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$now sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "same:$?"
  echo c > src/a.ts && git commit -qam app2
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$now DEPLOY_INTERVAL_MINUTES=60 sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "throttled:$?"
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$now sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "no-throttle:$?"
) 2>/dev/null | grep -E "^[a-z-]+:[0-9]$" > "$dt.out"
eq "the ignore step skips docs-only since the last deploy" "docs:0" "$(sed -n 1p "$dt.out")"
eq "the ignore step builds an app change since the last deploy, not only the last commit" "app:1" "$(sed -n 2p "$dt.out")"
eq "the ignore step skips any branch but main" "branch:0" "$(sed -n 3p "$dt.out")"
eq "the ignore step skips when nothing changed" "same:0" "$(sed -n 4p "$dt.out")"
eq "with DEPLOY_INTERVAL_MINUTES=60 the ignore step throttles a deploy under an hour after the last" "throttled:0" "$(sed -n 5p "$dt.out")"
eq "by default there is no throttle, so the day's last merge ships" "no-throttle:1" "$(sed -n 6p "$dt.out")"
if command -v node >/dev/null 2>&1; then
  (
    cd "$dt" && mkdir -p .github/workflows && cp "$root/templates/.github/workflows/deploy.yml" .github/workflows/ && mkdir -p scripts && cp "$root/templates/scripts/deploy-setup.sh" scripts/
    printf '{\n  "crons": [{"path": "/api/cron/cleanup", "schedule": "17 10 * * *"}]\n}\n' > web/vercel.json
    PATH_SAVE=$PATH; sh scripts/deploy-setup.sh guard web 90 >/dev/null 2>&1; echo "guard:$?"
    node -e 'const j=require("./web/vercel.json"); console.log(JSON.stringify([j.crons.length, j.git.deploymentEnabled.main, j.git.deploymentEnabled["*"], j.ignoreCommand]))'
    DEPLOY_NEVER_SHIPS="packs scripts" DEPLOY_HOSTED=yes sh scripts/deploy-setup.sh runner web 180 >/dev/null 2>&1; echo "runner:$?"
    node -e 'const j=require("./web/vercel.json"); console.log(JSON.stringify([j.crons.length, j.git.deploymentEnabled, j.ignoreCommand === undefined]))'
    grep -o 'cron: "[^"]*"' .github/workflows/deploy.yml
    tr -d ' \n' < .claude/deploy.json | sed 's/"_comment":"[^"]*",//'; echo
  ) 2>/dev/null > "$dt.setup"
  eq "the setup writes the guard and keeps the crons" "guard:0
[1,true,false,\"sh ../scripts/ci/vercel-ignore.sh\"]" "$(sed -n 1,2p "$dt.setup")"
  eq "the setup turns Git deploys off for the runner path and drops the ignore step" "runner:0
[1,false,true]" "$(sed -n 3,4p "$dt.setup")"
  eq "the setup never edits the Deploy workflow" 'cron: "17 * * * *"' "$(sed -n 5p "$dt.setup")"
  eq "the setup records the path, the folder, the interval and the never-ships folders" '{"path":"runner","appRoot":"web","intervalMinutes":180,"neverShips":["packs","scripts"]}' "$(sed -n 6p "$dt.setup")"
fi
mv "$dt" "$dt.done" 2>/dev/null || true

printf '\n# owner console (node)\n'
if command -v node >/dev/null 2>&1; then
  if node --test --test-reporter tap "$root"/console/test/*.test.js >"$root/tests/console.log" 2>&1; then
    node_count=$(sed -n 's/^# pass \([0-9]*\).*/\1/p' "$root/tests/console.log" | tr -d '\r')
    pass=$((pass + ${node_count:-0}))
    printf 'ok    %s console tests\n' "${node_count:-0}"
  else
    fail=$((fail + 1))
    printf 'FAIL  console tests, see tests/console.log\n'
    grep -E '^not ok|^# (fail|pass)' "$root/tests/console.log"
  fi
  mv "$root/tests/console.log" "$root/tests/console.log.last"
else
  printf 'skip  node is not installed, so the console tests did not run\n'
fi

printf '\n# drive skill scheduling\n'
drive_sched=$(sed -n '/^## Scheduling/,$p' "$root/skills/project-drive/SKILL.md")
for w in desktop terminal scheduled; do
  eq "drive skill scheduling names the $w way" "1" "$(printf '%s\n' "$drive_sched" | grep -qi "$w" && echo 1 || echo 0)"
done

printf '\n# drive release goal\n'
. "$root/scripts/drive/drive-lib.sh"
eq "next patch bumps the last part" "0.23.8" "$(next_patch 0.23.7)"
eq "next patch carries no overflow" "1.0.10" "$(next_patch 1.0.9)"
eq "next patch refuses a non-version" "" "$(next_patch latest)"
eq "release goal names version and count" "release 0.23.8 (3 plugin commits unreleased)" "$(release_goal 0.23.7 3)"
eq "release goal says commit for one" "release 0.23.8 (1 plugin commit unreleased)" "$(release_goal 0.23.7 1)"
eq "release goal silent at zero" "" "$(release_goal 0.23.7 0)"
eq "release goal silent with no count" "" "$(release_goal 0.23.7 '')"
eq "add goal goes before the stop line" "merge 5
release 0.1.1 (2 plugin commits unreleased)
stop: proposal ready for approval" "$(add_goal "$(printf 'merge 5\nstop: proposal ready for approval')" "release 0.1.1 (2 plugin commits unreleased)")"
eq "add goal turns an idle stop into a ready one" "release 0.1.1 (2 plugin commits unreleased)
stop: proposal ready for approval" "$(add_goal "stop: nothing to propose" "release 0.1.1 (2 plugin commits unreleased)")"
rel_dir=$(mktemp -d)
(
  cd "$rel_dir" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p plugin/.claude-plugin
  printf '{\n  "version": "0.1.0"\n}\n' > plugin/.claude-plugin/plugin.json
  git add -A && git commit -q -m release
  git branch -M main
  printf '%s\n' "$(plugin_unreleased_count)" > "$rel_dir/c0"
  echo a > plugin/a.txt; git add -A && git commit -q -m a
  echo other > other.txt; git add -A && git commit -q -m other
  echo b > plugin/b.txt; git add -A && git commit -q -m b
  printf '%s\n' "$(plugin_unreleased_count)" > "$rel_dir/c2"
  printf '{\n  "version": "0.1.1"\n}\n' > plugin/.claude-plugin/plugin.json
  git add -A && git commit -q -m bump
  printf '%s\n' "$(plugin_unreleased_count)" > "$rel_dir/c3"
  mv plugin/.claude-plugin/plugin.json plugin/.claude-plugin/p.bak
  printf '%s\n' "$(plugin_unreleased_count)" > "$rel_dir/cn"
)
eq "no commits since the release counts zero" "0" "$(cat "$rel_dir/c0")"
eq "counts only commits touching plugin since the version change" "2" "$(cat "$rel_dir/c2")"
eq "a version bump resets the count" "0" "$(cat "$rel_dir/c3")"
eq "no plugin version file prints nothing" "" "$(cat "$rel_dir/cn")"
eq "session brief names the unreleased count" "1" "$(grep -q 'unreleased commit' "$root/hooks/scripts/session-brief.sh" && echo 1 || echo 0)"
eq "drive skill names the release goal" "1" "$(grep -q 'release X.Y.Z' "$root/skills/project-drive/SKILL.md" && echo 1 || echo 0)"
eq "plan script adds the release goal" "1" "$(grep -q 'release_goal' "$root/scripts/drive/plan.sh" && echo 1 || echo 0)"

printf '\n# hook counterparts\n'
cp_file="$root/hooks/COUNTERPARTS.txt"
for cp_h in "$root"/hooks/scripts/block-*.sh "$root"/hooks/scripts/require-*.sh; do
  cp_n=$(basename "$cp_h" .sh)
  eq "hook $cp_n has a counterpart row" "1" "$(grep -c "^$cp_n |" "$cp_file")"
done
while IFS='|' read -r cp_n cp_c cp_r; do
  case "$cp_n" in '#'*|'') continue ;; esac
  cp_n=$(printf '%s' "$cp_n" | sed 's/ *$//'); cp_c=$(printf '%s' "$cp_c" | sed 's/^ *//; s/ *$//')
  case "$cp_c" in
    session-only) ok=1 ;;
    "none yet #"[0-9]*) ok=1 ;;
    "none yet"*) ok=0 ;;
    *) if [ -f "$root/templates/$cp_c" ]; then ok=1; else ok=0; fi ;;
  esac
  eq "counterpart row $cp_n is valid" "1" "$ok"
  [ -f "$root/hooks/scripts/$cp_n.sh" ] || eq "counterpart row $cp_n names a hook that exists" "1" "0"
done < "$cp_file"


printf '\n# the delete check\n'
dc="$root/templates/scripts/ci/delete-check.sh"
dr=$(mktemp -d)
git -C "$dr" init -q
git -C "$dr" config user.email t@example.com
git -C "$dr" config user.name t
printf 'one\ntwo\nthree\nfour\nfive\n' > "$dr/a.txt"
printf 'keep\n' > "$dr/b.txt"
git -C "$dr" add -A
git -C "$dr" commit -q -m base
base_sha=$(git -C "$dr" rev-parse HEAD)
git -C "$dr" mv a.txt moved.txt
git -C "$dr" commit -q -m move
move_sha=$(git -C "$dr" rev-parse HEAD)
git -C "$dr" rm -q b.txt
git -C "$dr" commit -q -m remove
del_sha=$(git -C "$dr" rev-parse HEAD)
eq "a rename is not a delete" "0" "$(cd "$dr" && PR_BODY= sh "$dc" "$base_sha" "$move_sha" >/dev/null 2>&1; echo $?)"
eq "a plain delete fails" "1" "$(cd "$dr" && PR_BODY= sh "$dc" "$move_sha" "$del_sha" >/dev/null 2>&1; echo $?)"
eq "a delete with a Deletes line passes" "0" "$(cd "$dr" && PR_BODY="Closes #1
Deletes: the file was a stray copy" sh "$dc" "$move_sha" "$del_sha" >/dev/null 2>&1; echo $?)"
eq "an empty Deletes line does not pass" "1" "$(cd "$dr" && PR_BODY="Deletes:" sh "$dc" "$move_sha" "$del_sha" >/dev/null 2>&1; echo $?)"
dc_body=$(batch_pr_body "$(printf '7\tTidy\n9\tRetire a file\n')" "$(carried_refs 'Closes #3' 7)
$(carried_refs 'Closes #4
Spec: specs/001-x
Deletes: the file was a stray copy
Mock: unchanged, copy only' 9)")
eq "a batch carries a member's check lines under its number" "From #9:
Deletes: the file was a stray copy
Mock: unchanged, copy only" "$(printf '%s\n' "$dc_body" | tail -n 3)"
eq "a batch of a member that retires a file with its reason stated passes" "0" "$(cd "$dr" && PR_BODY="$dc_body" sh "$dc" "$move_sha" "$del_sha" >/dev/null 2>&1; echo $?)"
eq "a batch whose members state no reason still fails" "1" "$(cd "$dr" && PR_BODY="$(batch_pr_body "$(printf '7\tTidy\n')" "$(carried_refs 'Closes #3' 7)")" sh "$dc" "$move_sha" "$del_sha" >/dev/null 2>&1; echo $?)"
eq "a carried Mock line reads as the member's" "copy only" "$(mock_escape "$dc_body")"
eq "a single pull request's body is read as before" "0" "$(cd "$dr" && PR_BODY="Deletes: the file was a stray copy" sh "$dc" "$move_sha" "$del_sha" >/dev/null 2>&1; echo $?)"
eq "without a number no header is added" "Deletes: x" "$(carried_refs 'Deletes: x')"
printf '\n# workspace install\n'
ws=$(mktemp -d)
mkdir -p "$ws/pn/packages/a" "$ws/pn/packages/b" "$ws/pn/packages/notpkg" "$ws/np/libs/x" "$ws/np/apps/y" "$ws/per/web"
printf 'packages:\n  - "packages/*"\n' > "$ws/pn/pnpm-workspace.yaml"
printf "lockfileVersion: '9.0'\n" > "$ws/pn/pnpm-lock.yaml"
echo '{"name":"a"}' > "$ws/pn/packages/a/package.json"
echo '{"name":"b"}' > "$ws/pn/packages/b/package.json"
echo '{"name":"root","workspaces":["libs/*","apps/y"]}' > "$ws/np/package.json"
echo '{}' > "$ws/np/package-lock.json"
echo '{"name":"x"}' > "$ws/np/libs/x/package.json"
echo '{"name":"y"}' > "$ws/np/apps/y/package.json"
echo '{"name":"web"}' > "$ws/per/web/package.json"
echo '{}' > "$ws/per/web/package-lock.json"
eq "a pnpm-workspace.yaml makes a pnpm root" "pnpm" "$(workspace_kind "$ws/pn")"
eq "a workspaces field with package-lock.json makes an npm root" "npm" "$(workspace_kind "$ws/np")"
eq "separate packages are not a workspace" "" "$(workspace_kind "$ws/per")"
eq "pnpm members come from the glob, only folders with a package.json" "packages/a
packages/b" "$(workspace_members "$ws/pn")"
eq "npm members come from the workspaces array" "apps/y
libs/x" "$(workspace_members "$ws/np")"
eq "the root lockfile is named by the tool" "pnpm-lock.yaml package-lock.json yarn.lock" "$(workspace_lockfile pnpm) $(workspace_lockfile npm) $(workspace_lockfile yarn)"
h1=$(workspace_hash "$ws/pn" pnpm)
eq "the hash names the lockfile and each member" "3" "$(echo "$h1" | tr ',' '\n' | wc -l | tr -d ' ')"
echo '{"name":"b","dependencies":{"z":"1"}}' > "$ws/pn/packages/b/package.json"
eq "a member's package.json changes the hash" "1" "$([ "$h1" != "$(workspace_hash "$ws/pn" pnpm)" ] && echo 1 || echo 0)"
eq "yarn installs immutably" "yarn install --immutable" "$(workspace_install_command "$ws/np" yarn)"
eq "npm installs with ci" "npm ci --no-audit --no-fund" "$(workspace_install_command "$ws/np" npm)"
eq "pnpm installs frozen" "1" "$(workspace_install_command "$ws/pn" pnpm | grep -c 'pnpm install --frozen-lockfile\|pnpm@9 install --frozen-lockfile')"
eq "the queue installs a workspace from its root" "1" "$(grep -c 'ensure_workspace "\$em_kind"' "$root/templates/scripts/ci/merge-queue.sh")"


printf '\n# a draft tokens file seeded from the mocks\n'
sl="$root/templates/scripts/design/seed-lib.mjs"
sq() { node --input-type=module -e "import * as s from 'file:///$(printf '%s' "$sl" | sed 's|^/\([a-zA-Z]\)/|\1:/|')'; $1"; }
eq "a style string gives its declarations" '[["font-family","'"'"'Display Serif'"'"', serif"],["font-size","32px"],["padding","16px 24px"]]' "$(sq 'console.log(JSON.stringify(s.parseStyle("font-family: '"'"'Display Serif'"'"', serif; font-size: 32px; padding: 16px 24px")))')"
eq "a generator's quoted key counts too" '[["font-size","13px"]]' "$(sq 'console.log(JSON.stringify(s.parseStyle("{\x27font-size\x27: \x2713px\x27}")))')"
eq "colours come out as six-digit hex" "#AABBCC #FF8000 #123456" "$(sq 'console.log(s.colorsIn("#abc rgb(255, 128, 0) #12345680").join(" "))')"
eq "a colour is light, dark or an accent" "light dark accent dark" "$(sq 'console.log(["#FAF7F0","#1B2638","#E4572E","#23305E"].map(s.classifyColor).join(" "))')"
eq "px values leave out em, zero and percent" "12 8" "$(sq 'console.log(s.pxValues("12px 8px 0 1em 50%").join(" "))')"
eq "a family skips the generic names and escapes" "Display Serif|serif Inter|system-ui" "$(sq 'const a=s.familyOf("\\\x27Display Serif\\\x27, serif"),b=s.familyOf("system-ui, Inter");console.log(a.name+"|"+a.fallback+" "+b.name+"|"+b.fallback)')"
eq "a scale is the most seen values, smallest first, named in order" "xs=4:3 sm=8:5 md=16:9" "$(sq 'console.log(s.buildScale({4:3,8:5,16:9,32:1},3).map(e=>e.key+"="+e.value+":"+e.seen).join(" "))')"
eq "Name and NameDark pair up; a lone screen does not" '{"Home.dc.html":"light","HomeDark.dc.html":"dark"}' "$(sq 'console.log(JSON.stringify(s.pairSides(["Home.dc.html","HomeDark.dc.html","Settings.dc.html","OnlyDark.dc.html"])))')"

sp=$(mktemp -d)
(
  cd "$sp" && mkdir -p scripts/design design && cp "$root/templates/scripts/design/seed-tokens.mjs" "$root/templates/scripts/design/seed-lib.mjs" scripts/design/
  node scripts/design/seed-tokens.mjs >/dev/null 2>&1; echo "empty $?"
  cp -r "$root/tests/fixtures/seed-tokens/design/mocks" design/mocks
  node scripts/design/seed-tokens.mjs --print > print.json; echo "print $? $([ -f design/tokens.json ] && echo wrote || echo none)"
  node scripts/design/seed-tokens.mjs >/dev/null; echo "first $? $([ -f design/tokens.json ] && echo tokens) $([ -f design/tokens.draft.json ] && echo draft)"
  cmp -s print.json design/tokens.json && echo "same" || echo "differs"
  printf '{"kept": true}\n' > design/tokens.json
  node scripts/design/seed-tokens.mjs >/dev/null; echo "second $? $(cat design/tokens.json | tr -d '\n ') $([ -f design/tokens.draft.json ] && echo draft)"
  node scripts/design/seed-tokens.mjs >/dev/null 2>&1; echo "third $?"
) > "$sp.out" 2>&1
eq "no mocks, exit 2" "empty 2" "$(sed -n 1p "$sp.out")"
eq "--print writes nothing" "print 0 none" "$(sed -n 2p "$sp.out")"
eq "with no tokens file, it writes design/tokens.json" "first 0 tokens " "$(sed -n 3p "$sp.out")"
eq "and --print shows the same draft" "same" "$(sed -n 4p "$sp.out")"
eq "an existing tokens file is kept; the draft goes beside it" 'second 0 {"kept":true} draft' "$(sed -n 5p "$sp.out")"
eq "and neither is overwritten on a second run" "third 1" "$(sed -n 6p "$sp.out")"
sj() { node -e 'const j=require(process.argv[1]);console.log(eval(process.argv[2]))' "$sp/print.json" "$1"; }
eq "the draft keeps the tokens file's shape" "ground accents gradients type radii spacing outputs" "$(sj '["ground","accents","gradients","type","radii","spacing","outputs"].filter(k=>k in j).join(" ")')"
eq "the draft says what a person must do" "yes" "$(sj 'j._draft.some(l=>/never the finished look/.test(l))&&j._draft.some(l=>/1 Name \/ NameDark/.test(l))?"yes":"no"')"
eq "the ground, light and dark from the pair, with seen counts" "page #FAF7F0 2, panel #FFFFFF 1, line #E3DED2 1, ink #1B2638 2, muted #5A6478 1, pageDark #14181F 1, panelDark #1F2530 1, inkDark #EDEFF3 2" "$(sj 'j.ground.map(g=>g.key+" "+g.hex+" "+g.seen).join(", ")')"
eq "the accents count the generator's palette" "accent #E4572E 3, accent2 #2E9E5B 1" "$(sj 'j.accents.map(a=>a.key+" "+a.stops[0]+" "+a.seen).join(", ")')"
eq "the families with the weights seen beside them" "body Inter 400 3, display Display Serif 800 2" "$(sj 'j.type.families.map(f=>f.key+" "+f.name+" "+f.weights.join("/")+" "+f.seen).join(", ")')"
eq "the type scale by size, largest first" "title display 32/800 1.1 0 false 2, heading body 16/600 1.5 0 false 5, subheading body 12/600 1.3 0.08 true 3" "$(sj 'j.type.roles.map(r=>[r.key,r.family,r.size+"/"+r.weight,r.lineHeight,r.letterSpacing,r.uppercase,r.seen].join(" ")).join(", ")')"
eq "radii and spacing as scales, counts under _seen" '{"small":8,"round":999} {"xs":8,"sm":12,"md":16,"lg":24} {"radii":{"small":3,"round":2},"spacing":{"xs":1,"sm":2,"md":3,"lg":4}}' "$(sj 'JSON.stringify(j.radii)+" "+JSON.stringify(j.spacing)+" "+JSON.stringify(j._seen)')"
eq "the bootstrap's mocks step runs the seeder" "1" "$(grep -c 'node scripts/design/seed-tokens.mjs' "$root/skills/project-bootstrap/SKILL.md" | awk '{print ($1>=1)?1:0}')"
printf '\n# deploy targets\n'
dt_tpl=$(cat "$root/templates/.github/workflows/deploy.yml")
dt_ci=$(printf 'jobs:\n  a:\n    runs-on: [self-hosted, windows]\n    steps:\n      - name: a\n        shell: %s\n' "'C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}'")
dt_win=$(. "$root/scripts/sync/sync-lib.sh"; filled_text "$dt_tpl" "$(ci_runs_on "$dt_ci")" "$(ci_shell "$dt_ci")")
dt_job() { printf '%s\n' "$2" | awk -v j="  $1:" '$0 == j {f=1; next} /^  [a-z-]*:$/ {f=0} f'; }
eq "the target defaults to vercel" "vercel" "$(. "$root/templates/scripts/ci/deploy-lib.sh"; t=$(json_string '{"path": "runner"}' target); echo "${t:-vercel}")"
eq "the Vercel jobs still run on the vercel and runner paths" "1 1" "$(printf '%s\n' "$dt_tpl" | grep -c "needs.plan.outputs.path == 'vercel' ||") $(printf '%s\n' "$dt_tpl" | grep -c "needs.plan.outputs.path == 'runner'")"
eq "the Cloudflare job runs only on the cloudflare path" "1" "$(printf '%s\n' "$dt_tpl" | grep -c "needs.plan.outputs.path == 'cloudflare'")"
eq "the workers in deploy order" "packages/service packages/web" "$(. "$root/templates/scripts/ci/deploy-lib.sh"; json_words '{"target": "cloudflare", "workers": ["packages/service", "packages/web"]}' workers)"
eq "each Worker deploys with wrangler in its folder, assets first when it has the script" "1 1" "$(dt_job deploy-cloudflare "$dt_tpl" | grep -c '(cd "$w" && npx wrangler deploy)') $(dt_job deploy-cloudflare "$dt_tpl" | grep -c '(cd "$w" && npm run assets)')"
eq "the Cloudflare job has both secrets" "2" "$(dt_job deploy-cloudflare "$dt_tpl" | grep -cE 'CLOUDFLARE_(API_TOKEN|ACCOUNT_ID): \$\{\{ secrets')"
eq "rendered for Windows, the plan and the Cloudflare job name Git's bash in every step" "1/1 3/3" "$(for j in plan deploy-cloudflare; do t=$(dt_job $j "$dt_win"); printf '%s/%s ' "$(printf '%s\n' "$t" | grep -c 'shell:.*Git\\bin\\bash.exe')" "$(printf '%s\n' "$t" | grep -c 'shell:')"; done | sed 's/ $//')"
eq "and never a bare bash there" "0" "$(printf '%s\n%s\n' "$(dt_job plan "$dt_win")" "$(dt_job deploy-cloudflare "$dt_win")" | grep -cE 'shell:[[:space:]]*(bash|RUN_SHELL)')"
eq "the sync takes a rendered copy as current, CRLF or not" "yes yes" "$(. "$root/scripts/sync/sync-lib.sh"; same_text "$dt_win" "$(filled_text "$dt_tpl" "$(ci_runs_on "$dt_ci")" "$(ci_shell "$dt_ci")")" | tr -d '\n'; printf ' '; same_text "$(printf '%s\n' "$dt_win" | sed 's/$/\r/')" "$dt_win")"
printf '\n# waits for a runner and the machine line\n'
. "$root/templates/scripts/ci/batch-lib.sh"
. "$root/templates/scripts/ci/run-lib.sh"
wl_dir=$(mktemp -d); wl_now=1800000000
waits_append "$wl_dir/q/waits.tsv" $((wl_now - 31 * 86400)) "run 1: old" 3 3 9
waits_append "$wl_dir/q/waits.tsv" $((wl_now - 3600)) "run 2: test" 3 3 4
eq "a wait is written, and one past thirty days is trimmed" "1 run 2: test 3 3 4" "$(wc -l < "$wl_dir/q/waits.tsv" | tr -d ' ') $(cut -f3-6 "$wl_dir/q/waits.tsv" | tr '\t' ' ')"
waits_append "$wl_dir/q/waits.tsv" $((wl_now - 60)) "run 3: lint	x" 3 3 2
eq "newest last, a tab in the job name kept out of the columns" "2 run 3: lint x" "$(wc -l < "$wl_dir/q/waits.tsv" | tr -d ' ') $(tail -n 1 "$wl_dir/q/waits.tsv" | cut -f3)"
waits_append "$wl_dir/q/waits.tsv" $((wl_now - 30)) "run 4: app" 3 3 1
eq "the brief line, from the log" "Jobs waited for a runner 3 times this week, 4 minutes at most, when all 3 were busy." "$(waits_line "$(cat "$wl_dir/q/waits.tsv")" "$wl_now")"
eq "no wait this week, no line" "" "$(waits_line "$(printf '%s\t-\tj\t3\t3\t5' $((wl_now - 8 * 86400)))" "$wl_now")"
eq "no log, no line" "" "$(waits_line "" "$wl_now")"
eq "some runners idle is said so" "Jobs waited for a runner once this week, 1 minute at most, with up to 2 of 3 busy." "$(waits_line "$(printf '%s\t-\tj\t2\t3\t1' $((wl_now - 60)))" "$wl_now")"
eq "the machine line" "16 cores, 9 runner(s) on this machine across repositories, 2 busy now; the rule allows 8 (one per two cores)" "$(machine_line 16 9 2)"
eq "one over the rule" "1" "$(machine_over 16 9)"
eq "at the rule is not over" "0" "$(machine_over 16 8)"
eq "odd cores round down" "1" "$(machine_over 5 3)"
eq "the brief prints the machine line only past the rule" "L|" "$(machine_brief_line "$(printf '1\t16\t9\t2\tL')")|$(machine_brief_line "$(printf '1\t16\t8\t2\tL')")"
eq "the queue logs its waits" "1" "$(grep -c 'waits_append .scratch/queue/waits.tsv' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the watch prints the machine line" "1" "$(grep -c 'echo "machine line: $mline"' "$root/templates/scripts/ci/runner-watch.sh")"
eq "the brief reads the waits log and the machine file" "1 1" "$(grep -c 'waits_line "$(tail -n 500' "$root/hooks/scripts/session-brief.sh") $(grep -c 'machine_brief_line "$(head -n 1' "$root/hooks/scripts/session-brief.sh")"
mv "$wl_dir" "$wl_dir.done" 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
