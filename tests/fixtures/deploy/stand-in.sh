#!/bin/sh
# A stand-in for "npx wrangler deploy". STAND_IN_DIR holds a count file;
# STAND_IN_FAILS is how many tries print STAND_IN_FIXTURE and fail before
# one succeeds.
n=$(cat "$STAND_IN_DIR/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$STAND_IN_DIR/count"
if [ "$n" -le "${STAND_IN_FAILS:-0}" ]; then
  cat "$STAND_IN_FIXTURE"
  exit 1
fi
echo "Deployed rooftop-garden."
