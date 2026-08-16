# Codebase Audit Prompt

Source: [Aaron Francis, “Audit your codebase”](https://gist.github.com/aarondfrancis/8735edbe48532f97ee5ea818db4dbd47)

Use the prompt at the source link for a read-only, agent-managed audit of a complete codebase. It reviews data structures, state models, control flow, algorithms, and ownership.

The prompt requires the audit coordinator to:

- List all subsystems and define exact ownership boundaries.
- Assign bounded, non-overlapping reviews.
- Find only useful simplifications and permit explicit skip decisions.
- Verify evidence, remove duplicate findings, and reject weak abstractions.
- Check coverage, ownership overlap, material value, report completeness, and priority order.
- Leave the audited repository unchanged.

Keep the source link as the canonical copy so that this inbox does not become stale when the author updates the prompt.
