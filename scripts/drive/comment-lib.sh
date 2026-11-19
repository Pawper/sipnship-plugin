#!/bin/sh
# A comment from a file is its contents, never its name. `gh api` with a lowercase -f field
# sends the literal string "@file"; only the uppercase -F field reads the file, and a
# drive tick once left a comment whose whole text was a file name. Sourced by
# comment.sh and by the readers of the drive issue. Pure, except ask_plain_verdict,
# which reaches the deployed service.

# ask_plain_verdict TEXT: reads TEXT as a builder who is not yet technical
# would, through the deployed service's model-read check (spec 024,
# `POST /app/{owner}/{repo}/asks/plain`). Prints "pass" when it reads
# plainly; "fail" then one line of what was unclear each, when it does not;
# nothing when no verdict could be had at all. A missing verdict is never
# taken as a pass or a fail: the caller posts as it always did, the same
# rule the route itself keeps for a model that is not set up. Needs
# scripts/ci/service-auth.sh (for service_sign_in), curl and node; prints
# nothing without any of them.
#
# Today this always prints nothing in practice: service_sign_in makes a
# repo-scoped bearer token, good on /v1/ calls; this route is read only
# with a browser's own signed-in cookie (packages/web/src/app.ts's `read`,
# the only thing it calls out through, forwards the cookie header and
# never the bearer). There is not yet a way for this script to get that
# cookie, so every call here reaches the route signed out and returns
# nothing, same as if the service were unreachable.
ask_plain_verdict() {
  [ -f scripts/ci/service-auth.sh ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v node >/dev/null 2>&1 || return 0
  # The same guard requests.sh uses: an identity token lives only minutes, so it is asked for again at each use and
  # never kept; the guard only avoids re-sourcing the file, and lets a test stand in for service_sign_in itself.
  [ -n "${QUEUE_SERVICE_AUTH_LOADED:-}" ] || { . scripts/ci/service-auth.sh; QUEUE_SERVICE_AUTH_LOADED=1; }
  service_sign_in || return 0
  apv_full=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
  [ -n "$apv_full" ] || return 0
  apv_body=$(printf '%s' "$1" | node -e 'process.stdout.write(JSON.stringify({ text: require("fs").readFileSync(0, "utf8") }))' 2>/dev/null)
  [ -n "$apv_body" ] || return 0
  apv_reply=$(printf 'Authorization: Bearer %s\n' "$sv_token" | curl -s --max-time 10 -X POST -H @- -H 'content-type: application/json' --data "$apv_body" "${SIPNSHIP_URL:-https://sipnship.dev}/app/$apv_full/asks/plain" 2>/dev/null)
  [ -n "$apv_reply" ] || return 0
  printf '%s' "$apv_reply" | node -e '
    let raw = "";
    process.stdin.on("data", (d) => { raw += d; });
    process.stdin.on("end", () => {
      try {
        const v = JSON.parse(raw);
        if (typeof v.passes !== "boolean") return;
        if (v.passes) { console.log("pass"); return; }
        console.log("fail");
        for (const u of Array.isArray(v.unclear) ? v.unclear : []) if (typeof u === "string" && u) console.log(u);
      } catch {}
    });
  ' 2>/dev/null
}

# unoffered_permission TEXT
# For a comment that is an `Instructions:` step (the builder's to do outside
# the app), the name of a token permission it asks for that a fine-grained
# GitHub token does not have ("Checks"), or nothing. A step that cannot be
# done sat in Needs you for a day once, and the drive repeated it every tick.
unoffered_permission() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    NR == 1 && $0 !~ /^[ \t*_]*Instructions:/ { exit }
    { l = tolower($0) }
    l ~ /(^|[^a-z])checks"?:? *(\(|:)? *(read|write)/ || l ~ /(^|[^a-z])"?checks"? +permission/ { print "Checks"; exit }'
}

# comment_refusal FILE
# Nothing when FILE can be posted; else why not, in plain words: the file is
# missing, empty, or its whole text is a path (a body that starts with "@" and
# has no space is a file name that never got read).
comment_refusal() {
  [ -f "$1" ] || { echo "There is no file $1 to post."; return 0; }
  cr_body=$(tr -d '\r' < "$1")
  [ -n "$(printf '%s' "$cr_body" | tr -d ' \t\n')" ] || { echo "The file $1 is empty; nothing is posted."; return 0; }
  cr_perm=$(unoffered_permission "$cr_body")
  [ -z "$cr_perm" ] || { echo "The step asks for a \"$cr_perm\" permission, which GitHub does not offer on a fine-grained token, so the builder could not do it. Name only permissions that exist there (Actions, Administration, Commit statuses, Contents, Issues, Pull requests, Workflows); the drive reads checks from the Actions runs and commit statuses and needs no Checks permission."; return 0; }
  # Instructions open with why, and a command always has words of its own (ask_check, scripts/ci/ask-lib.sh).
  if [ -f scripts/ci/ask-lib.sh ] && printf '%s\n' "$cr_body" | head -n 1 | grep -qiE '^[ 	*_]*Instructions:'; then
    cr_word=$( . scripts/ci/ask-lib.sh; printf '%s\n' "$cr_body" | ask_check )
    case "$cr_word" in noreason|barecommand) cr_say=$( . scripts/ci/ask-lib.sh; ask_fix "$cr_word" ); echo "The Instructions would stop a builder who is not technical: $cr_say."; return 0 ;; esac
  # An ask with choices (never Instructions, which keeps the rule above) is read by the service as a builder who is
  # not yet technical would read it, when that read can be had at all (ask_plain_verdict).
  elif [ -f scripts/ci/ask-lib.sh ] && [ "$( . scripts/ci/ask-lib.sh; printf '%s\n' "$cr_body" | ask_verdict )" = one ]; then
    cr_plain=$(ask_plain_verdict "$cr_body")
    case "$cr_plain" in
      fail*)
        cr_why=$(printf '%s\n' "$cr_plain" | tail -n +2 | awk '{ if (NR > 1) printf "; "; printf "%s", $0 }')
        echo "A builder who is not yet technical could not answer this as written: ${cr_why:-it was returned with nothing named}."
        return 0 ;;
    esac
  fi
  case "$cr_body" in
    @*) case "$cr_body" in *[[:space:]]*) ;; *) echo "The text of $1 is only a file name ($cr_body); it would post the name, not the file. Write the words into the file."; return 0 ;; esac ;;
  esac
}

# without_bare_path_comments LINES
# The drive issue's comment lines (the body is the last tab-separated field)
# without any whose whole body is a bare "@path": one slip is never read as an
# answer, a request or a proposal.
without_bare_path_comments() {
  printf '%s\n' "$1" | awk -F'\t' '$NF ~ /^@[^ \t\\]+$/ { next } { print }'
}
