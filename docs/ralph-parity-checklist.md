# Ralph V2 Parity Checklist

`ralph_wiggum_loop_v2.sh` remains the behavior reference until the required items pass.

| Reference behavior | Required | Status | Proof |
|---|---|---|---|
| Read and normalize Beadwork tasks | Yes | Pass | `Hancho.WorkSource.Beadwork`; Beadwork contract tests |
| Select ready, ranged, and single tasks | Yes | Pass | Ready selection and CLI tests |
| Check task dependencies | Yes | Pass | Blocked-item selection tests |
| Claim and close work with recovery | Yes | Pass | Beadwork and reconciliation tests |
| Load exact allowed file and directory scope | Yes | Pass | Work-spec and Git scope tests |
| Detect tracked, untracked, copied, renamed, and deleted paths | Yes | Pass | Git porcelain and rename tests |
| Stop changes outside admitted scope | Yes | Pass | Build scope-violation test |
| Require dependency and migration approvals | Yes | Pass | Gate and stale-approval tests |
| Create one isolated worktree per work order | Yes | Pass | Git and Build.V1 tests |
| Keep commit, push, and merge authority out of the harness | Yes | Pass | Harness protocol, Build.V1, publication, and merge tests |
| Run configured checks before and after the candidate commit | Yes | Pass | Build receipt assertions |
| Limit repair attempts | Yes | Pass | Bounded-repair tests |
| Detect a changed target branch | Yes | Pass | Build and merge target-change tests |
| Write an accepted-revision receipt | Yes | Pass | Candidate receipt tests |
| Reconcile push and work-item effects | Yes | Pass | Publication, work-source, and reconciler tests |
| Use shared `_build` and `deps` symlinks | No | Not required | Use a configured cache policy later. |
| Parse LLMux execution-card Markdown fields | No | Not required | Use the Hancho work-order contract. |
| Merge directly into the checked-out branch by default | No | Not required | Build.V1 stops at a candidate by default. |
| Put runtime state in the Git common directory | No | Not required | Use the ignored repository-root `./.hancho/` folder. |

All required parity items pass. On 2026-08-16, Hancho completed local work order `run-nf58qkgcdf0u` in this repository without direct Ralph-script use. The Bash file remains as a marked reference. Hancho is the default driver.
