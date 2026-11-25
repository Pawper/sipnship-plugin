#!/bin/sh
# What a sync report found, kept inside .git for the session brief to carry to the dashboard's "setup is current" item
# (#2703): counts, and the commit and plugin version they were read at, so a later commit or a newer plugin makes the
# reading stale and the brief drops it. Sourced by sync-templates.sh; needs apply, only, changed, edited, missing,
# known and version.
#
# Whether the known list covers every release a project may be on (#2703, settled here): templates/KNOWN.txt is
# rebuilt by known-hashes.sh --all, which walks each owned path's full git history with no bound, so once an
# installed plugin carries it, it recognises a file from any release ever shipped, however old. The one way a sync
# run still cannot tell is a plugin copy old enough to predate KNOWN.txt's own introduction: it ships no such file,
# $known is empty, and no file can be judged plugin, edited or the project's own. That is said plainly, as "beyond
# the list", rather than guessed as current or counted at all.
keep_shipped() {
  [ -z "$only" ] && [ "$apply" = no ] && [ -d .git ] || return 0
  if [ -z "$known" ]; then
    printf '{"head":"%s","version":"%s","older":0,"edited":0,"beyondList":true}\n' "$(git rev-parse HEAD 2>/dev/null)" "$version" > .git/sipnship-shipped.json 2>/dev/null || true
    return 0
  fi
  ks_edited=0; ks_older=0
  for ks_p in $changed; do case " $edited " in *" $ks_p "*) ks_edited=$((ks_edited + 1)) ;; *) ks_older=$((ks_older + 1)) ;; esac; done
  ks_older=$((ks_older + $(printf '%s' "$missing" | wc -w | tr -d ' ')))
  printf '{"head":"%s","version":"%s","older":%s,"edited":%s}\n' "$(git rev-parse HEAD 2>/dev/null)" "$version" "$ks_older" "$ks_edited" > .git/sipnship-shipped.json 2>/dev/null || true
}
