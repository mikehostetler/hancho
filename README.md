# Hancho

Hancho is the local driver for my personal software factory.

New and unorganized material goes in [`inbox/`](inbox/).

Build plans for the `hancho` CLI go in [`plan/`](plan/).

The repository root contains the Elixir application. Hancho coordinates versioned Build.V1, Plan.V1, and Audit.V1 workflows through replaceable CLI harnesses. Durable state and local configuration stay in the ignored `./.hancho/` folder.

Hancho uses `toml_elixir` to read standard TOML and `zoi` to validate the basic configuration shape. The live factory controller uses the built-in OTP `:gen_statem` behavior. `erlexec` owns harness process groups and stops their child processes after cancellation, timeout, or owner failure. A moved escript extracts the checked `erlexec` helper to the user cache. Set `HANCHO_NATIVE_CACHE` to select a different cache root.

```sh
mix test.fast
mix test
mix check
./scripts/build-release.sh
./hancho init
./hancho doctor
./hancho run walking_skeleton first-run
```

Use `mix test.fast` for the short local feedback loop. Use `mix test` or `mix check` to run integration and acceptance tests before a commit.

Read the [operating guide](docs/operating-guide.md), [installation and rollback guide](docs/install-and-upgrade.md), and [Ralph V2 migration guide](docs/ralph-migration-guide.md).
