#!/bin/sh
# The proof for specs/027-hooks-in-node: every case in tests/fixtures/hooks-node/
# (one file per case, named HOOK--slug.json, the event as Claude sends it) is
# fed to the shell hook and to the Node program, and the verdict (the exit
# code) and the words a person sees (standard error) must match line for line.
# Sourced by tests/run.sh; uses its eq. The slug's first word picks the setup:
#   queue-*   a project that has the queue script
#   budget-*  a fresh budget reading: low-* 120 left, plenty-* 4,120, warn-* 1,200
#   local-*   a repository on branch task with quick checks that pass, fail or
#             run out of time (pass-, fail-, late-), none (nochecks-), or on main
#   *--ask-*  gh is a stand-in that prints the comment named by the file's last
#             part (one-recommended, two-unrecommended, none)
# The project is Maya's rooftop-garden app throughout.

hn_dir="$root/tests/fixtures/hooks-node"
hn_base=$(mktemp -d)
hn_native() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

# hn_project SLUG: make the folder a case runs in; print its path.
hn_project() {
  hp_d="$hn_base/p$$-$(printf '%s' "$1" | cksum | cut -d ' ' -f 1)"
  mkdir -p "$hp_d/.scratch" "$hp_d/.claude"
  case "$1" in
    queue-*) mkdir -p "$hp_d/scripts/ci"; : > "$hp_d/scripts/ci/merge-queue.sh" ;;
    budget-*)
      hp_left=4120
      case "$1" in budget-low-*) hp_left=120 ;; budget-warn-*) hp_left=1200 ;; esac
      hp_now=$(date +%s)
      printf '%s\t%s\t5000\t%s\t4900\t5000\t%s\n' "$hp_now" "$hp_left" "$((hp_now + 3030))" "$((hp_now + 3030))" > "$hp_d/.scratch/gh-budget.txt" ;;
    local-*)
      ( cd "$hp_d" && git init -q -b main && git config user.email t@t && git config user.name t && git config core.autocrlf false
        printf '.scratch/\n' > .gitignore; printf 'beds\n' > beds.txt
        case "$1" in
          local-nochecks-*) ;;
          *) mkdir -p scripts/ci
             case "$1" in
               local-pass-*) printf 'exit 0\n' > scripts/ci/checks-local.sh ;;
               local-late-*) printf 'echo "Still running: the size check"\nexit 3\n' > scripts/ci/checks-local.sh ;;
               *) printf 'echo "Failed: lib/watering.ts has 50 lines, over the limit of 40"\nexit 1\n' > scripts/ci/checks-local.sh ;;
             esac ;;
        esac
        git add -A && git commit -q -m base
        case "$1" in local-fail-on-main) ;; *) git checkout -q -b task ;; esac ) >/dev/null 2>&1 ;;
  esac
  hn_native "$hp_d"
}

# hn_ask_gh: a stand-in gh that prints the comment in $ASK_FIXTURE, then the marker.
hn_ask_gh() {
  mkdir -p "$hn_base/askbin"
  cat > "$hn_base/askbin/gh" <<'GH'
#!/bin/sh
[ -n "$ASK_FIXTURE" ] && [ -f "$ASK_FIXTURE" ] && { cat "$ASK_FIXTURE"; printf '%s\n' "--- next comment ---"; }
exit 0
GH
  chmod +x "$hn_base/askbin/gh"
  hn_native "$hn_base/askbin"
}

# hn_words KIND INPUT PROJECT HOOK: "rc=N" and what the hook said, as the shell
# hook (KIND sh) or the Node program (KIND node) runs it.
hn_words() {
  hw_askpath=$PATH; hw_fx=
  case "$5" in
    *--ask-*) hw_askpath="$hn_askdir:$PATH"; hw_fx="$fx/ask/${5##*--}.md" ;;
  esac
  if [ "$1" = sh ]; then
    hw_out=$(PATH=$hw_askpath ASK_FIXTURE=$hw_fx HOOK_LOG=0 CLAUDE_PROJECT_DIR=$3 sh "$root/hooks/scripts/$4.sh" < "$2" 2>&1)
  else
    hw_out=$(PATH=$hw_askpath ASK_FIXTURE=$hw_fx HOOK_LOG=0 CLAUDE_PROJECT_DIR=$3 node "$root/hooks/node/run.js" pre-bash --only "$4" < "$2" 2>&1)
  fi
  printf 'rc=%s\n%s' "$?" "$hw_out"
}

hn_askdir=$(hn_ask_gh)
hn_cases=0; hn_refused=0; hn_allowed=0
for hn_f in "$hn_dir"/*.json; do
  hn_name=$(basename "$hn_f" .json)
  hn_hook=${hn_name%%--*}
  hn_slug=${hn_name#*--}
  hn_proj=$(hn_project "$hn_slug")
  hn_in="$hn_base/in-$hn_name"
  sed "s|@PROJECT@|$hn_proj|g" "$hn_f" > "$hn_in"
  hn_sh=$(hn_words sh "$hn_in" "$hn_proj" "$hn_hook" "$hn_name")
  hn_nd=$(hn_words node "$hn_in" "$hn_proj" "$hn_hook" "$hn_name")
  hn_cases=$((hn_cases + 1))
  case "$hn_sh" in "rc=2"*) hn_refused=$((hn_refused + 1)) ;; *) hn_allowed=$((hn_allowed + 1)) ;; esac
  eq "$hn_name: the verdict and the words are the same" "$hn_sh" "$hn_nd"
done
