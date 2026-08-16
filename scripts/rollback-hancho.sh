#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s DESTINATION\n' "$0" >&2
  exit 64
fi

destination="$1"
backup="${destination}.previous"

[ -f "$backup" ] || { printf 'No prior escript exists at %s\n' "$backup" >&2; exit 66; }
"$backup" version >/dev/null
cp "$backup" "${destination}.rollback"
chmod 0755 "${destination}.rollback"
mv "${destination}.rollback" "$destination"
printf 'Restored %s from %s\n' "$destination" "$backup"
