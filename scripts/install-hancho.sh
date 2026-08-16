#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'Usage: %s BUILT_ESCRIPT DESTINATION\n' "$0" >&2
  exit 64
fi

source_file="$1"
destination="$2"
backup="${destination}.previous"
temporary="${destination}.installing"

[ -f "$source_file" ] || { printf 'Missing escript: %s\n' "$source_file" >&2; exit 66; }
mkdir -p "$(dirname "$destination")"

if [ -f "$destination" ]; then
  cp -p "$destination" "$backup"
fi

cp "$source_file" "$temporary"
chmod 0755 "$temporary"

if ! "$temporary" version >/dev/null; then
  printf 'New escript failed its version check. Existing install is unchanged.\n' >&2
  rm -f "$temporary"
  exit 70
fi

mv "$temporary" "$destination"
printf 'Installed %s. Prior version: %s\n' "$destination" "$backup"
