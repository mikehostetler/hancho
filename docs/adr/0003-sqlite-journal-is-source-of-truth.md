# ADR 0003: SQLite Journal Is the Source of Truth

Status: Accepted

SQLite is the only source of truth for work-order state and transition events. Hancho does not write a second `events.jsonl` state journal in the first version.

The database changes the current state and appends its event in one transaction. Raw harness streams, prompts, check output, reports, and receipts remain files. SQLite stores each file path, hash, size, media type, creation time, and retention class.

This choice prevents two event stores from becoming different after a crash. Hancho can add a JSON Lines export later. The export will be a derived view, not operational state.
