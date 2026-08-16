# Compatibility

Hancho 0.1 supports these local runtimes:

| Component | Supported range |
|---|---|
| Elixir for source builds | 1.20.x |
| Erlang/OTP for the escript | 27 through 29 |
| Git | 2.39 or later |
| SQLite CLI | 3.40 or later, with JSON output support |
| tmux | 3.3 or later when detached mode is used |
| Operating system | Current macOS on Apple Silicon and x86-64 Ubuntu Linux |

`hancho doctor` checks the Erlang release, Git, SQLite, local state, configuration, database schema, workflow routes, and optional tools. A missing tmux is a warning for foreground use and a clear error for detached use.

The default test suite uses fake local harnesses and no network. Tests that use real models, GitHub, Beadwork, Hex, or deployment services are optional and separate.
