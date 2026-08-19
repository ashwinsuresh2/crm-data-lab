# Codex Project Instructions

## Role

Codex is normally the independent reviewer and second implementation lane for this repository. It may implement a bounded task only in an isolated worktree or branch with explicit path ownership.

## Read first

Before acting, read:

- `docs/PROJECT_CHARTER.md`
- `docs/FIRST_VERTICAL_SLICE.md`
- `docs/WORK_GRAPH.md`
- `CLAUDE.md`
- Relevant files under `docs/decisions/` if that directory exists

## Multi-agent behavior

Use subagents for independent, bounded work such as exploration, tests, security review, and alternative implementation analysis. Keep the main thread focused on contracts, integration, and final judgment.

Do not assign parallel writers to overlapping files. Use worktrees for independent implementation branches. Prefer read-only subagents for verification.

## Product and architecture invariants

- PostgreSQL is authoritative.
- The UI writes only through the CRM API.
- Business record, audit event, and outbox event commit atomically.
- Consumers are idempotent.
- Search and analytics are derived and rebuildable.
- Every tenant-owned record includes `tenant_id`.
- No paid or cloud dependency may be added without an approved decision record.
- No replacement engine may trigger production side effects while in shadow mode.

## Review standard

Do not merely summarize a diff. Try to disprove that it is safe and correct. Check:

- Contract violations.
- Cross-tenant data leakage.
- Duplicate delivery and retry behavior.
- Transaction boundaries.
- Missing authorization.
- Migration safety.
- Event ordering and versioning.
- Failure recovery.
- Tests that assert implementation details instead of behavior.
- Hidden cost floors or always-on infrastructure.

Return findings with file and symbol references, severity, reproduction steps, and the smallest safe fix.
