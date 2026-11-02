# Sourced by session-brief.sh: the screen lines of the brief (comparisons across
# platforms, against mocks, and mocks fallen behind). Moved out of the main script
# so it stays small; uses its has, add and have_git.
# Screens due a comparison across platforms: a file-pair check never says
# that one platform's screen looks nothing like the other's.
if has screens && [ -f scripts/ci/parity.txt ] && [ -f "$here/../../templates/scripts/design/design-lib.sh" ]; then
  . "$here/../../templates/scripts/design/design-lib.sh"
  due=$(stale_screens "$(parity_pairs "$(cat scripts/ci/parity.txt)")" "$(cat design/screens.txt 2>/dev/null)" "$(date +%Y-%m-%d)" 14 | head -n 6 | paste -sd';' - | sed 's/;/; /g')
  [ -z "$due" ] || add "Screens not compared across platforms in 14 days: $due. After comparing: sh scripts/design/screens.sh compare NAME"
fi

# Built screens due a look beside their mock: only the screens with an
# @/route in scripts/ci/mocks.txt, which the screens job renders.
if has screens && [ -f scripts/ci/mocks.txt ] && [ -f "$here/../../templates/scripts/design/design-lib.sh" ] && [ -f "$here/../../templates/scripts/ci/mock-lib.sh" ]; then
  . "$here/../../templates/scripts/design/design-lib.sh"
  . "$here/../../templates/scripts/ci/mock-lib.sh"
  routed=$(mock_routes "$(cat scripts/ci/mocks.txt)")
  [ -z "$routed" ] || due=$(stale_screens "$routed" "$(cat design/screens.txt 2>/dev/null)" "$(date +%Y-%m-%d)" 14 mock | head -n 6 | paste -sd';' - | sed 's/;/; /g')
  [ -z "$routed" ] || [ -z "$due" ] || add "Screens not compared with their mock in 14 days: $due. After looking at the side-by-side: sh scripts/design/screens.sh compare --mock NAME"
fi

# Screens whose mock has fallen behind their UI by more than the
# stale-after commits in scripts/ci/mocks.txt (20 by default). Local git only.
if has screens && [ -f scripts/ci/mocks.txt ] && [ "$have_git" = yes ] && [ -f "$here/../../templates/scripts/ci/mock-check.sh" ]; then
  sm=$(run_bounded 6 sh "$here/../../templates/scripts/ci/mock-check.sh" --stale 2>/dev/null | head -n 6 | paste -sd';' - | sed 's/;/; /g')
  [ -z "$sm" ] || add "Mocks behind their screens: $sm. Update the mock in design/mocks/, or say in the next pull request why it still holds."
fi
