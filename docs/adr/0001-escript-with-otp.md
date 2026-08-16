# ADR 0001: Escript with OTP

Status: Accepted

Hancho is a Mix project at the repository root. `mix escript.build` creates the first installation artifact. `Hancho.CLI` is the escript entry point. The application uses an OTP supervision tree for controllers and active work orders.

An escript is the first package because it is easy to copy and run on a system with a compatible Erlang runtime. It is not an operating-system-neutral static executable. Hancho must check the runtime and external command requirements in `hancho doctor`.

An OTP release can be evaluated later. It is not the first package.
