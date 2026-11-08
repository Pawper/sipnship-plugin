#!/bin/sh
# Pure rules for builds that find a place: which place in the builder's
# order takes one job, from the order, the wait limit, the ceilings, the
# kept runner and the job's system. The same rule as the service's
# placement rule, written for sh and awk so the place job needs nothing but
# a shell and gh on the machine it lands on. Loaded by scripts/ci/batch-lib.sh;
# nothing here calls git or gh. Tested with one fixture a case in
# tests/fixtures/place/.
#
# The order is one line of NAME=VALUE words, as the repository variable
# SIPNSHIP_PLACES holds it (the builder saves it on Settings; their agent
# mirrors it here):
#   order=own,tenki,github   the places switched on, first first
#   wait=10                  minutes a job may wait for your machines;
#                            "none" for as long as it takes
#   connected=tenki          hosted places that have run a job here, or the
#                            builder has just connected
#   ceiling.tenki=20:move    a monthly ceiling in dollars, and what happens
#                            at it: move on, or wait
#   spend.tenki=6.40         this month's spend so far, in dollars
#   refused.tenki=EPOCH      when the place last left a job waiting; it is
#                            passed over for an hour after (the drain's
#                            rescue writes it, in SIPNSHIP_PLACE_REFUSED)
#   usual=6                  a job's usual minutes, for the wait estimate

# place_providers: the places a job can run, one line each:
# id, name, systems, then the runs-on label for linux, windows and macos
# ("-" for none). The service's provider entries hold the same; a core test
# keeps the two equal. The builder's own machines are reached by their own
# labels, never one of these.
place_providers() {
  printf 'own\tYour machines\tlinux,windows,macos\t-\t-\t-\n'
  printf 'tenki\tTenki\tlinux,macos\ttenki-standard-small-2c-4g\t-\t-\n'
  printf 'github\tGitHub\tlinux,windows,macos\tubuntu-latest\twindows-latest\tmacos-latest\n'
}

# places_get ORDER KEY: the value of one word of the order; nothing when absent.
places_get() {
  printf '%s\n' "$1" | tr ' ' '\n' | awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }'
}

# place_kind EVENT HEAD_REF: which job it is. A pull request's own jobs
# ("pr") overflow when your runners are full; a batch's (a batch-* branch),
# a rush test head's (rush-*) and main's keep the kept runner.
place_kind() {
  case "$1:$2" in
    pull_request*:batch-*) echo batch ;;
    pull_request*:rush-*) echo rush ;;
    pull_request*) echo pr ;;
    *) echo main ;;
  esac
}

# own_facts LABELS KEEP RUNNERS QUEUED: what the rule reads about your
# machines, as "online free kept queued". RUNNERS is one runner a line,
# "status<TAB>busy<TAB>labels" as GitHub lists them; a runner counts when it
# carries every label of the job's (the "pr" label aside, which marks the
# runners that are not kept). KEEP is "on" when one runner is kept for the
# batch and main (CI_KEEP_RUNNER): the online runner without "pr".
own_facts() {
  printf '%s\n' "$3" | tr -d '\r' | awk -F'\t' -v want="$1" -v keep="$2" -v queued="${4:-0}" '
    BEGIN { n = split(want, w, ",") }
    NF >= 3 {
      split($3, have, ","); delete h; for (i in have) h[have[i]] = 1
      ok = 1; for (i = 1; i <= n; i++) if (w[i] != "pr" && w[i] != "" && !(w[i] in h)) ok = 0
      if (!ok || $1 != "online") next
      online++; if ($2 != "true") free++; if (!("pr" in h)) kept = 1
    }
    END { if (keep != "on") kept = 0; printf "%d %d %d %d\n", online, free, kept, queued + 0 }'
}

# place_job ORDER SYSTEM KIND LABELS FACTS GONE NOW
# The place for one job. SYSTEM is linux, windows or macos; KIND is
# place_kind's; LABELS are the job's own runs-on labels on your machines,
# comma-separated; FACTS is own_facts's line, or "unknown" when the runners
# could not be read (your machines are then taken to be able to, so the
# rescue, not a guess, moves the job); GONE is "yes" when GitHub will not
# start hosted jobs (HOSTED_MINUTES); NOW is epoch seconds.
# Prints "place<TAB>runs-on<TAB>waits<TAB>why<TAB>skipped":
#   place    the id of the place the job runs on
#   runs-on  the job's labels there: LABELS on your machines ("pr" kept
#            only for a pull request's own job), else the place's label
#   waits    "no"; "yes" when no place could take it and it goes to the
#            first place and waits; "ceiling" when it holds at a place that
#            reached its ceiling, because the builder chose to wait there
#   why      why the first place did not take it, "-" when it did
#   skipped  every place passed over, "id:reason" comma-separated, or "-"
# The first place in the order that can take the job and is under its
# ceiling wins. When none can, the job goes to the first place and waits.
place_job() {
  place_providers | awk -F'\t' -v order="$1" -v sys="$2" -v kind="$3" -v labels="$4" -v facts="$5" -v gone="$6" -v now="$7" '
    function tok(k,   n, a, i, v) { v = ""; n = split(order, a, " "); for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) v = substr(a[i], length(k) + 2); return v }
    function has(list, x,   n, a, i) { n = split(list, a, ","); for (i = 1; i <= n; i++) if (a[i] == x) return 1; return 0 }
    function pos(x) { return x > 0 ? x : 0 }
    function ownlabels(   n, a, i, out) { out = ""; n = split(labels, a, ","); for (i = 1; i <= n; i++) if (a[i] != "pr" || kind == "pr") out = out (out == "" ? "" : ",") a[i]; return out }
    function label(id,   l) { l = (sys == "linux") ? lin[id] : ((sys == "windows") ? win[id] : mac[id]); return l == "-" ? "" : l }
    function runson(id) { return id == "own" ? ownlabels() : label(id) }
    # The wait for your machines, in minutes: jobs ahead divided by runners, times a usual job.
    function ownwait(   usable, fr) {
      usable = (kind == "pr") ? pos(online - kept) : online
      fr = (kind == "pr") ? pos(free - kept) : free
      if (queued < fr) return 0
      return ((queued - fr + 1) / usable) * usual
    }
    function reason(id,   usable, c, cc, ref) {
      if (id == "own") {
        if (facts == "unknown") return ""
        usable = (kind == "pr") ? pos(online - kept) : online
        if (online == 0) return "offline"
        if (usable == 0) return "busy"
        # A batch, a rush head and main keep the kept runner and do not leave for a wait.
        if (limit != "none" && ownwait() > limit + 0 && (kind == "pr" || kept == 0)) return "busy"
        return ""
      }
      if (!has(systems[id], sys) || label(id) == "") return "system"
      if (id == "github" && gone == "yes") return "gone"
      if (id != "github" && !has(tok("connected"), id)) return "not-connected"
      ref = tok("refused." id)
      if (ref != "" && now - ref < 3600) return "credit"
      c = tok("ceiling." id)
      if (c != "") { split(c, cc, ":"); if (tok("spend." id) + 0 >= cc[1] + 0) { atwait = (cc[2] == "wait"); return "ceiling" } }
      return ""
    }
    function out(id, w,   s) { s = (skipped == "") ? "-" : skipped; printf "%s\t%s\t%s\t%s\t%s\n", id, runson(id), w, (first == "" ? "-" : first), s; done = 1 }
    { systems[$1] = $3; lin[$1] = $4; win[$1] = $5; mac[$1] = $6; known[$1] = 1 }
    END {
      split(facts, f, " "); online = f[1] + 0; free = f[2] + 0; kept = f[3] + 0; queued = f[4] + 0
      limit = tok("wait"); if (limit == "") limit = "none"
      usual = tok("usual"); if (usual == "") usual = 6
      n = split(tok("order"), o, ","); m = 0
      for (i = 1; i <= n; i++) if (o[i] in known) on[++m] = o[i]
      if (m == 0) { on[++m] = "own" }
      skipped = ""; first = ""
      for (i = 1; i <= m && !done; i++) {
        atwait = 0; r = reason(on[i])
        if (r == "") { out(on[i], "no"); break }
        if (r == "ceiling" && atwait) { out(on[i], "ceiling"); break }
        if (first == "") first = r
        skipped = skipped (skipped == "" ? "" : ",") on[i] ":" r
      }
      if (!done) out(on[1], "yes")
    }'
}

# place_name ID [IN_SENTENCE]: the place as a screen names it. Inside a
# sentence your machines are "your machines".
place_name() {
  case "$1" in
    own) if [ -n "$2" ]; then echo "your machines"; else echo "Your machines"; fi ;;
    *) place_providers | awk -F'\t' -v id="$1" '$1 == id { print $2; f = 1 } END { if (!f) print id }' ;;
  esac
}

# place_words PLACED: the run's one calm line for place_job's answer. A
# fallback is the promise holding, so it never sounds like a failure.
place_words() {
  IFS='	' read -r pw_place pw_runs pw_waits pw_why pw_skipped <<PW_EOF
$1
PW_EOF
  pw_where=$(place_name "$pw_place" in)
  case "$pw_waits" in
    ceiling) echo "$(place_name "$pw_place") reached the ceiling you set, and you chose to wait. This build waits until next month or until you raise it."; return ;;
    yes) echo "No place could take this build. It waits for $pw_where until one is free."; return ;;
  esac
  case "$pw_why" in
    -) echo "This ran on $pw_where."; return ;;
    offline) echo "Your machine was offline, so this ran on $pw_where."; return ;;
    busy) echo "Your runners were busy, so this ran on $pw_where."; return ;;
    gone) echo "GitHub's free minutes were used up, so this ran on $pw_where."; return ;;
  esac
  pw_prev=$(place_name "${pw_skipped%%:*}")
  case "$pw_why" in
    credit) echo "$pw_prev was out of credit, so this ran on $pw_where." ;;
    ceiling) echo "$pw_prev reached the ceiling you set, so this ran on $pw_where." ;;
    system) echo "$pw_prev does not run this kind of build, so this ran on $pw_where." ;;
    not-connected) echo "$pw_prev was not connected yet, so this ran on $pw_where." ;;
  esac
}

# place_outputs < LINES: the place job's two outputs from one line a job,
# "name<TAB>place<TAB>runs-on". Prints the runs-on map, then the where map,
# each one line of JSON: {"checks":["self-hosted","linux","pr"],"app":"tenki-standard-small-2c-4g"}
# and {"checks":"own","app":"tenki"}. A job reads its own with
# fromJSON(needs.place.outputs.runs-on).checks.
place_outputs() {
  tr -d '\r' | awk -F'\t' '
    NF >= 3 {
      n = split($3, l, ",")
      if ($2 == "own") { v = "["; for (i = 1; i <= n; i++) v = v (i > 1 ? "," : "") "\"" l[i] "\""; v = v "]" } else v = "\"" $3 "\""
      r = r (r == "" ? "" : ",") "\"" $1 "\":" v
      w = w (w == "" ? "" : ",") "\"" $1 "\":\"" $2 "\""
    }
    END { print "{" r "}"; print "{" w "}" }'
}

# b_lap WHAT: say how long the step since the last lap took (bt holds its start).
b_lap() { b_now=$(date +%s); echo "  timing: $1 took $((b_now - bt))s"; bt=$b_now; }
