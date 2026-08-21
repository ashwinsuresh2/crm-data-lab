# Sprint 0001 — Confirmation Pass: Architecture Lens

- **Reviewed commit:** `87efe3f` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** fresh architecture-reviewer agent instance (read-only; independent of prior passes)
- **Prior review:** docs/reviews/sprint-0001-barrier-architecture.md

## Per-item verdicts

1. **F1 container_name pins — PASS.** local-topology §2: commands address service keys (`postgres`, `kafka`); physical names Compose-derived from `name: crmlab` (`crmlab-postgres-1`, `crmlab_postgres-data`, `crmlab_default`); deliberate-absence rationale explicit (daemon-global names collide the moment a second project instance starts). §10 self-check updated. Only remaining `container_name` occurrences are the two deliberate-absence statements.
2. **F3 pinned volume/network names — PASS.** Ban extended to volumes and networks ("no daemon-global `name:` pinning anywhere"); project-relative keys deriving `crmlab_postgres-data`/`crmlab_kafka-data`; default network `crmlab_default`. The §5 scoping guarantee now states it is true *because* names are project-derived, naming the silent-shared-volume hazard. Parallel instances via unique project name per test run/worktree explicitly permitted and supported, with the honest host-port caveat.
3. **F2/F4 replay + down -v honesty — PASS.** §6 opens with the blockquoted precondition (replay only when PostgreSQL and its outbox survive; after `down -v` "there is nothing to replay from"); the §2 KRaft bullet carries the same condition; "recoverable-by-rebuild" greps to zero across docs/specs; §5 WARNING states `down -v` destroys both authoritative PostgreSQL data and Kafka data, the after-state is "a fresh migrated/seeded environment, not a restoration," no automated backup is part of Sprint 0001, and gives the manual `pg_dump` command (also a §8 table row).
4. **F5 topic naming — PASS.** §7 item 3: names illustrative only, owned by Node E, deliberately domain-oriented (`crm.events.v1`, not `crm.outbox.v1`); §8 commands match. The only `crm.outbox` occurrence left is the negative example itself.
5. **F6 Kafka in product contract — PASS.** Case-insensitive grep in product-behavior.md: 0 occurrences; event-stream language throughout; §7 records the vendor-name-removal ruling including AC-4's cite-by-position.
6. **Regression sweep — PASS, no new coupling or hidden cost.** Outbox protocol remains three short phases with no transaction/lock across the network call; `claim_id` is the sole ownership guard on all three transitions; nothing assumes broker-specific behavior — the only broker-facing concept is "publish and wait for acknowledgement," satisfied by any Kafka-compatible, WarpStream, or future Mojo engine behind Node E's client seam. Receipt lifecycle walls off future external side effects behind a decision record. Four-state derivation is derived (not stored), references outbox/receipt rows only. Linkage columns are domain-oriented; inspection is plain SQL. Fleet unchanged: two containers + three host processes; approved tech list only; open formats; modular monolith intact; tenant isolation strengthened; $0 idle-cost floor restated; `/readyz` still not Kafka-gated.
   - Non-blocking observation (pre-existing style, no ruling covers it): database-contract.md and domain-model.md name Kafka in prose — infrastructure-side contracts where vendor naming was accepted; the F6 ruling covered only the product contract. No action required.

## Findings

No findings. No unresolved major items; no minor residue requiring action.

## Verdict

**FREEZE** — all five prior findings verifiably resolved per the human rulings; the remediated outbox/receipt/state machinery introduces no new coupling, boundary leak, or cost; the Sprint 0001 contracts are architecture-frozen for Sprint 0002 implementation.
