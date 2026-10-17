#!/bin/sh
# Pure helpers for writing a setting into an env file. Nothing here reads
# or writes a file; the caller passes the text in and writes the text out.

# env_set TEXT KEY VALUE
# TEXT is the content of an env file. Print it with KEY set to VALUE: the
# first "KEY=" line (also "export KEY=") replaced, keeping its export
# prefix, or a "KEY=VALUE" line added at the end when there is none. Other
# lines are untouched, so comments and order survive.
env_set() {
  [ -n "$1" ] || { printf '%s=%s\n' "$2" "$3"; return 0; }
  printf '%s\n' "$1" | tr -d '\r' | awk -v key="$2" -v val="$3" '
    BEGIN { done = 0 }
    {
      line = $0
      if (!done && match(line, "^(export[ \t]+)?" key "[ \t]*=")) {
        prefix = (line ~ /^export[ \t]+/) ? "export " : ""
        print prefix key "=" val
        done = 1
        next
      }
      print line
    }
    END { if (!done) print key "=" val }'
}

# random_password [LENGTH]
# A password of LENGTH (default 32) letters and digits from the system's
# randomness, for a database that will never see it typed.
random_password() {
  rp_n=${1:-32}
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((rp_n * 2)) | tr -dc 'A-Za-z0-9' | cut -c1-"$rp_n"
  else
    od -An -tx1 -N $((rp_n * 2)) /dev/urandom | tr -d ' \n' | cut -c1-"$rp_n"
  fi
}
