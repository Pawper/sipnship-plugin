#!/bin/sh
# What a sync report found, kept inside .git for the session brief to carry to the dashboard's "setup is current" item
# (#2703): counts, and the commit and plugin version they were read at, so a later commit or a newer plugin makes the
# reading stale and the brief drops it. Sourced by sync-templates.sh; needs apply, only, changed, edited, missing and version.
keep_shipped() {
  [ -z "$only" ] && [ "$apply" = no ] && [ -d .git ] || return 0
  ks_edited=0; ks_older=0
  for ks_p in $changed; do case " $edited " in *" $ks_p "*) ks_edited=$((ks_edited + 1)) ;; *) ks_older=$((ks_older + 1)) ;; esac; done
  ks_older=$((ks_older + $(printf '%s' "$missing" | wc -w | tr -d ' ')))
  printf '{"head":"%s","version":"%s","older":%s,"edited":%s}\n' "$(git rev-parse HEAD 2>/dev/null)" "$version" "$ks_older" "$ks_edited" > .git/sipnship-shipped.json 2>/dev/null || true
}
