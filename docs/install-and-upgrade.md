# Build, install, upgrade, and rollback

## Build and checksum

From a clean checkout, run:

```sh
./scripts/build-release.sh
shasum -a 256 -c hancho.sha256
```

This creates one versioned `hancho` escript and `hancho.sha256`. The build needs Elixir 1.20. The installed escript needs a supported Erlang/OTP runtime and the `sqlite3` executable.

## Install or upgrade

Choose an explicit destination that you own:

```sh
./scripts/install-hancho.sh ./hancho "$HOME/.local/bin/hancho"
hancho doctor --repo /path/to/repository
```

The installer checks the new file before it replaces the destination. It keeps the prior file as `hancho.previous`.

Hancho 0.1 uses database schema 3. Startup applies forward migrations in transactions. It does not downgrade a database. Keep a copy of `./.hancho/hancho.sqlite3` before an upgrade when the upgrade notes name a schema change.

## Rollback

Stop the factory first. Then run:

```sh
./scripts/rollback-hancho.sh "$HOME/.local/bin/hancho"
```

The prior escript can open state only when it supports the current database schema. If an upgrade migrated the database past the prior binary, restore the saved database copy with the prior escript. Hancho refuses a newer schema without changing it.
