# Project Instructions: World-Class CRM + Replaceable Data Platform

## Mission

Build a competitive, externalizable CRM whose first user is the founder and whose data infrastructure is deliberately designed as a learning and replacement laboratory.

The product must be excellent at relationship history, follow-up, pipeline, search, auditability, customization, and eventually automatic email/calendar capture. The infrastructure must let us compare Apache Kafka, WarpStream, and a future Mojo event engine; Apache Spark, LakeSail, and a future Mojo batch engine; and PostgreSQL search, OpenSearch, and a future Mojo search engine.

## Governing principle

**World-class seams, tiny fleet.**

Overengineer contracts, correctness, tenant isolation, auditability, replay, recovery, and benchmarkability. Do not overprovision CPU or introduce a service merely because large companies use it.

## Current scope

Build only the first vertical slice described in `docs/FIRST_VERTICAL_SLICE.md` until its acceptance tests pass.

## Agent orchestration rules

1. Begin every substantial task by reading `docs/PROJECT_CHARTER.md`, `docs/FIRST_VERTICAL_SLICE.md`, `docs/WORK_GRAPH.md`, and relevant decision records.
2. Convert work into bounded nodes with explicit inputs, outputs, owned paths, acceptance tests, and dependencies.
3. Delegate independent read-heavy work in parallel.
4. Use worktree-isolated agents for parallel writers.
5. Never assign two writing agents overlapping path ownership.
6. Use plain code for deterministic merging, sorting, deduplication, and validation; do not spend an agent on mechanical plumbing.
7. Put read-only verifier agents on every merge edge.
8. Stop discovery loops after two consecutive rounds produce no new findings.
9. Do not merge code merely because it looks plausible. Run objective checks.
10. The lead agent integrates; specialist agents do not independently redesign cross-cutting contracts.

## One-orchestrator rule

For any work item, exactly one tool is the implementation lead. Claude Code may lead while Codex reviews, or Codex may lead while Claude reviews. They must not both write to the same branch or worktree.

## Architecture rules

- The browser never writes directly to PostgreSQL, Kafka, OpenSearch, S3, or analytics stores.
- All meaningful writes pass through the CRM API.
- PostgreSQL is authoritative truth.
- Record changes, audit records, and outbox events commit in one transaction.
- Event consumers are idempotent and assume at-least-once delivery.
- Kafka-compatible infrastructure is behind a stable client/configuration boundary.
- Search and analytics are derived and rebuildable.
- Every tenant-owned row and event includes `tenant_id` from day one.
- No external side effect may occur in shadow-engine comparison mode.
- Prefer open formats and stable contracts: SQL migrations, OpenAPI, JSON Schema/Avro/Protobuf as chosen, Parquet, and Iceberg when introduced.

## Initial technology constraints

For the first vertical slice use:

- TypeScript.
- React/Next.js for the web application.
- A TypeScript API as a modular monolith.
- PostgreSQL.
- Ordinary Apache Kafka running locally in Docker.
- One background worker.
- Docker Compose.
- Automated tests.

Do not introduce Kubernetes, Spark, OpenSearch, Temporal, Flink, ClickHouse, MongoDB, DynamoDB, or cloud infrastructure until the vertical slice is correct and the relevant decision record is approved.

## Quality gates

Every implementation branch must pass:

- Type checking.
- Linting.
- Unit tests.
- Integration tests.
- Database migration tests.
- Tenant-isolation tests.
- Duplicate-event/idempotency tests.
- `git diff --check`.
- Independent correctness review.
- Independent security review for auth, permissions, inputs, secrets, or data access.

## Safety rules

- Never commit secrets, tokens, passwords, `.env` files, customer data, or generated credentials.
- Never use destructive Git commands unless the human explicitly requests them.
- Never push directly to `main`.
- Never disable tests to make a branch pass.
- Never silently widen scope.
- Never add a paid service without documenting the expected monthly floor and obtaining human approval.

## Communication

At the end of each agent task, report:

1. What was changed or learned.
2. Files touched.
3. Tests run and exact results.
4. Known risks or unresolved questions.
5. Whether the output is ready for integration.
