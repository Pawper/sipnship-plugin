# Reading every open pull request for the round: REST lists them, and each one's state, red count and busy flag are overlaid on the snapshot.
# Sourced by plan.sh, which sets snapshot, tab, us and the other round variables; the function leaves rest_lines, pr_shas,
# held_since, pull_links, pr_list and the overlaid snapshot set for the caller (one shell, no subshell).

read_open_pull_requests() {
  rest_lines=""; pr_shas=""
  pr_list=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [(.number | tostring), .head.ref, ([.labels[].name] | join(",")), ((.body // "") | [splits("\r?\n")] | map(select(test("^Queue: hold"; "i"))) | first // ""), ((.body // "") | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]] | join(",")), ((.body // "") | [scan("(?i)\\b(?:refs?|references|spec for|part of|relates to|related to):? #([0-9]+)") | .[0]] | join(","))] | join("\u001f")' 2>/dev/null | tr -d '\r')
  # One separator that is not whitespace, so a pull request with no hold line or no labels keeps its empty field; a tab would collapse it and shift the Closes numbers left.
  pull_links=$(pull_link_row "$pr_list")
  while IFS="$us" read -r p_num p_ref p_labels p_hold p_closes p_refs; do
    [ -n "$p_num" ] || continue
    plan_say "reading pull request $p_num"
    p_info=$(gh api "repos/{owner}/{repo}/pulls/$p_num" --jq '[(.mergeable_state // ""), .head.sha] | @tsv' 2>/dev/null | tr -d '\r')
    p_state=$(printf '%s' "$p_info" | cut -f1); p_sha=$(printf '%s' "$p_info" | cut -f2)
    pr_shas="${pr_shas}${p_num}${tab}${p_sha}
  "; p_reds=0; p_ci=$(printf '%s\n' "$snapshot" | awk -F'\t' -v n="$p_num" '$1 == "pr" && $2 == n { print $4 }')
    # A rollup still reading pending after every check ended and one failed or was cancelled is red.
    if [ "$p_ci" = pending ] && [ "$(head_settled_red "$p_sha")" = yes ]; then p_ci=red; snapshot=$(printf '%s\n' "$snapshot" | awk -F'\t' -v OFS='\t' -v n="$p_num" '$1 == "pr" && $2 == n { $4 = "red" } { print }'); fi
    p_mainred=none
    if [ "$p_ci" = red ]; then
      p_runs=$(gh api "repos/{owner}/{repo}/actions/runs?branch=$p_ref&event=pull_request&status=failure&per_page=100" --jq '.workflow_runs[] | [(.id | tostring), .head_sha, (.created_at | fromdateiso8601 | tostring)] | @tsv' 2>/dev/null | tr -d '\r')
      p_reds=$(red_count "$(printf '%s\n' "$p_runs" | cut -f2)")
      # A red that main itself had at the time (the same check failing there) is not the pull request's own: it does not count
      # toward set-aside, and once main is right the pull request needs main merged in (the mainred field, round-lib.sh).
      if [ "$p_reds" -gt 0 ]; then
        [ -n "${main_checks_read:-}" ] || { main_checks=$(main_finished_checks); main_checks_read=yes; }
        p_fails=$(run_failed_checks "$p_runs")
        p_main=$(main_reds "$p_fails" "$main_checks" | grep -c .)
        if [ "$p_main" -gt 0 ]; then
          p_reds=$(( p_reds - p_main ))
          if [ "$p_reds" -le 0 ]; then
            p_reds=0
            if [ "$(main_now_green "$p_fails" "$main_checks")" = yes ]; then p_mainred=fixed; else p_mainred=waiting; fi
          fi
        fi
      fi
    fi
    # Someone else on it? Only for one the drive would send an agent to (it conflicts or is red): a head commit under 10 minutes (red) or 30 (conflicting)
    # old means an agent is at work. Comments, the drive's own posts, a worktree and a check re-run never count: none ends when an
    # agent does, so a pull request nobody works would wait for ever.
    p_busy=no; p_head=
    if [ "$p_state" = dirty ] || [ "$p_ci" = red ]; then
      p_head=$(gh api "repos/{owner}/{repo}/commits/$p_sha" --jq '.commit.committer.date | fromdateiso8601' 2>/dev/null | tr -d '\r')
      p_busy=$(recently_touched "$p_head" "" "$(date +%s)" "$( [ "$p_ci" = red ] && echo 10 || echo 30)")
    fi
    p_pend=no; [ "$p_ci" = red ] && p_pend=$(head_checks_pending "$p_sha")  # a red from an older commit is not the newest commit failing
    # A red the round waits on (its newest commit's checks still running, or its reds from main) is timed from that commit.
    if [ "$p_ci" = red ] && { [ "$p_pend" = yes ] || [ "$p_mainred" = waiting ]; }; then
      [ -n "$p_head" ] || p_head=$(gh api "repos/{owner}/{repo}/commits/$p_sha" --jq '.commit.committer.date | fromdateiso8601' 2>/dev/null | tr -d '\r')
      held_since="${held_since:-}${p_num}${tab}${p_head}
"
    fi
    rest_lines="${rest_lines}${p_num}${tab}${p_state}${tab}${p_reds}${tab}$(held_by "$p_labels" "$p_hold")${tab}${p_busy}${tab}${p_pend}${tab}${p_mainred}
"
  done <<EOF_PRS
$pr_list
EOF_PRS
  [ -n "$rest_lines" ] && snapshot=$(overlay_rest "$snapshot" "$rest_lines")
}
