#!/usr/bin/env bash
set -euo pipefail

MIX_ENV=prod mix escript.build
chmod 0755 hancho
shasum -a 256 hancho > hancho.sha256
./hancho version

printf 'Built %s and %s\n' "$(pwd)/hancho" "$(pwd)/hancho.sha256"
