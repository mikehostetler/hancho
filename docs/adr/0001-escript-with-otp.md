# ADR 0001: Escript with OTP

Status: Accepted

Hancho is a Mix project at the repository root. `mix escript.build` creates the first installation artifact. `Hancho.CLI` is the escript entry point. The application uses an OTP supervision tree for controllers, OS process workers, and active work orders. The live factory controller uses the built-in `:gen_statem` behavior. The durable work-order workflow engine stays a separate pure transition function.

Hancho includes the `erlexec` helper in the escript. At startup, Hancho checks and extracts the helper to a private user cache when the helper is not present on the file system. The `HANCHO_NATIVE_CACHE` environment variable can select the cache root.

An escript is the first package because it is easy to copy and run on a system with a compatible Erlang runtime. It is not an operating-system-neutral static executable. Hancho must check the runtime and external command requirements in `hancho doctor`.

An OTP release can be evaluated later. It is not the first package.
