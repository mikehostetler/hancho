# Hancho

Hancho is the local driver for my personal software factory.

New and unorganized material goes in [`inbox/`](inbox/).

Build plans for the `hancho` CLI go in [`plan/`](plan/).

The repository root contains the Elixir application. Hancho coordinates versioned Build.V1, Plan.V1, and Audit.V1 workflows through replaceable CLI harnesses. Durable state and local configuration stay in the ignored `./.hancho/` folder.

```sh
mix check
./scripts/build-release.sh
./hancho init
./hancho doctor
./hancho run walking_skeleton first-run
```

Read the [operating guide](docs/operating-guide.md), [installation and rollback guide](docs/install-and-upgrade.md), and [Ralph V2 migration guide](docs/ralph-migration-guide.md).
