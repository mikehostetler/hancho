# Migration from `ralph_wiggum_loop_v2.sh`

The Bash driver is a reference file. Hancho is the default driver.

| Ralph V2 input or file | Hancho equivalent |
|---|---|
| `--only ID` | Select with Beadwork, then `hancho run build ID`; or configure the factory pull source. |
| `--start-at`, `--end-at`, `--max` | Use Beadwork ready selection and the factory WIP limit. |
| `--include-blocked` | Resolve the Beadwork dependency or use an explicit policy decision. Blocked work is not released by default. |
| `--dry-run` | Inspect `hancho queue`, `hancho guidance show`, or use delivery `--dry-run`. |
| `--model MODEL` | `hancho run ... --model MODEL` or a station route in `.hancho/config.toml`. |
| `--grok-arg`, `--permission-mode` | Put harness-specific behavior in a protocol adapter, not workflow flags. |
| `--max-fix-attempts` | `.hancho/config.toml` `limits.max_fix_attempts`. |
| `--no-claim`, `--no-close` | Work-record policy and explicit Beadwork adapter actions. |
| `--push`, `--remote`, `--branch` | `hancho publish RUN_ID` with explicit remote and Hancho-owned branch policy. |
| `.git/llmux-execution/` | Ignored repository-local `./.hancho/`. |
| execution-card Markdown | Hancho JSON work specification plus canonical GitHub and Beadwork references. |
| receipt files | `./.hancho/runs/RUN_ID/receipts/` with SQLite artifact indexes. |

Hancho owns worktrees, checks, candidate commits, publication, receipts, recovery, and closure. A harness cannot commit, push, merge, publish, deploy, or close work.
