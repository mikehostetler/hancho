# ADR 0002: SQLite CLI for the Escript

Status: Accepted

Hancho uses the `sqlite3` executable for its first operational store.

A direct Elixir SQLite driver can contain a native library in its application `priv` folder. Native-library extraction and loading make a moved escript more difficult to support. The installed SQLite CLI supplies transactions, process locking, JSON output, and a single database file without a native library inside the escript.

Hancho sends complete SQL transactions to one SQLite process. It escapes all SQL values in one module. It records the SQLite version in doctor output. If `sqlite3` is absent or incompatible, Hancho stops before it creates a work order.

A direct driver can replace this choice only after it passes the moved-escript test on every supported system.
