#!/bin/sh
# Pure helpers for the merge queue's batch mode. Nothing here calls git or
# gh, so every function is tested with strings in tests/run.sh; the one
# exception, batch_folder_repair, is tested on a scratch repository.
#
# The functions live in queue/rules-*.sh, beside this file, one library a
# step. A plain sh cannot say where a sourced file is, so the folder is
# found: bash says (BASH_SOURCE), and a caller names its own folder ($here,
# or the repository's scripts/ci) before it sources this file.
bl_dir=""
for bl_c in "$(dirname "${BASH_SOURCE:-.}")" "${here:-.}" "${here:-.}/ci" scripts/ci "${root:-.}/templates/scripts/ci"; do
  if [ -f "$bl_c/queue/rules-batch.sh" ]; then bl_dir=$bl_c; break; fi
done
if [ -z "$bl_dir" ]; then echo "batch-lib.sh: the queue/ folder beside it was not found" >&2; return 1; fi
. "$bl_dir/queue/rules-batch.sh"
. "$bl_dir/queue/rules-drain.sh"
. "$bl_dir/queue/rules-serial.sh"
. "$bl_dir/queue/rules-requests.sh"
. "$bl_dir/queue/rules-deploy.sh"
. "$bl_dir/queue/rules-checkout.sh"
