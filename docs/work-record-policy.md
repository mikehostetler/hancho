# GitHub and Beadwork Work-Record Policy

GitHub records what the factory promises. Beadwork records how the factory performs the work.

## Canonical links

- A root Beadwork item has one comment in this form: `Hancho-GitHub-Issue: ISSUE_URL`.
- A GitHub Issue has one comment in this form: `Hancho-Beadwork-Root: BEADWORK_ID`.
- Hancho also stores both references on the local work order. The local copy supports recovery. It does not replace either external record.

## Beadwork threshold

Create a root Beadwork item when work has dependencies, needs more than one agent session, is expected to take more than 30 minutes, or needs durable decomposition. A small, single-session change can run directly from a GitHub Issue.

## Closure order

1. Keep Beadwork open while implementation, review, merge, or required delivery is active.
2. Close Beadwork after execution and required merge or delivery effects are confirmed.
3. Close the GitHub Issue only after customer acceptance and required delivery are confirmed.
4. Keep both records open when an external effect is uncertain.

The final result summary belongs in the GitHub Issue. Beadwork keeps execution detail and a short result link.

## GitHub labels

Hancho does not write derived execution-state labels in the first version. Labels remain owner-managed commitment metadata.

## Synchronization

Hancho does not copy complete task lists in both directions. It posts only scope changes, owner decisions, blockers, link markers, and final delivery results to GitHub. Routine harness progress stays in the local journal and Beadwork.
