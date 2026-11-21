# Sourced by session-brief.sh (and its tests): the plugin-only warning
# about the standing issues' email, in a file of its own so adding it never
# grows session-brief-lib.sh, already over its line limit (#2116).
#
# Without a connected SipNShip project the Drive and Merge queue issues
# were opened under the builder's own gh sign-in, so GitHub emails them for
# every comment an agent posts there. Setup (project-bootstrap) says this
# once, in its final message; the brief repeats it every session while the
# builder is still subscribed, read with the sign-in the plugin has, and
# falls silent once they are not.

# service_connected FULLNAME TOKENS_JSON: "yes" when the tokens file (spec
# 006, ~/.sipnship/tokens.json) names this repository, from a machine
# having run npx sipnship connect --repo for it; "no" otherwise, including
# when the file does not exist (TOKENS_JSON empty). While a repository is
# not connected it has no app to post the log issues as (#2116), so the
# plugin's own warning applies.
service_connected() {
  case "$2" in *"\"fullName\":\"$1\""*) echo yes ;; *) echo no ;; esac
}

# subscribed_warn_line PAIRS: PAIRS is "number<TAB>subscribed" per standing
# issue read (the Drive and Merge queue issues, each by its label), one per
# line; SUBSCRIBED is GitHub's own word for the signed-in person on that
# issue's subscription endpoint, "true" or "false", empty when the read
# found no custom subscription (GitHub's default for the issue's own
# author, who filed it, is subscribed, so empty counts as still subscribed
# too). Nothing when every issue answered false, so a builder who already
# unsubscribed on each is told once by setup (#2116) and never nagged by
# the brief again.
subscribed_warn_line() {
  swl_named=$(printf '%s\n' "$1" | awk -F'\t' '$1 != "" && $2 != "false" { printf "#%s ", $1 }' | sed 's/ $//')
  [ -n "$swl_named" ] || return 0
  printf 'You are still subscribed to %s, this project'"'"'s log issues; without a connected SipNShip project, GitHub emails you for every comment an agent posts there. Unsubscribe once on each issue'"'"'s own page (the bell by its title, or Unsubscribe at its foot).\n' "$swl_named"
}
