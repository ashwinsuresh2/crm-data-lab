# Sprint 0001 — Wave-1 Barrier Review: QA Lens

- **Reviewed commit:** `1c4dd59` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** qa-verifier agent (read-only)
- **Documents:** docs/specs/product-behavior.md, domain-model.md, database-contract.md, local-topology.md

---

## Question B — Consumer observability: determination and recommendation

**Determination: `consumer_receipt` records only successful processing.** The table (database-contract.md §4) has exactly four columns — `consumer_name`, `event_id`, `tenant_id`, `processed_at` — and §6 inserts the receipt in the same transaction as the consumer's side effects. A failed consumer attempt rolls that transaction back, so a failure leaves zero rows anywhere in PostgreSQL. Consequences, verified against the derivation table in §7:

- An event whose consumer fails 1 time or 1,000 times derives as "published" — indistinguishable from "consumer hasn't run yet." No `attempt_count`, no `last_error`, no timestamp of any consumer attempt.
- §7's claim "the complete path is inspectable end to end" is therefore false for the failure half of the consumer leg. The contract is asymmetric: publisher failures are inspectable (`attempt_count`/`last_error` on `outbox_event`), consumer failures are invisible.
- product-behavior.md journey step 6 ("within tens of seconds … reaches 'processed'") and AC-5 become undiagnosable on failure: the test times out at "published" with no DB evidence distinguishing worker-down, poison message, or receipt bug. The overclaim lives in database-contract.md §7, not in P.

**Recommendation: enrich the receipt** (rather than narrow the claims). The charter explicitly overengineers auditability; the outbox already carries attempt metadata for the publisher leg, so enriching symmetrizes the seam; AC-5's bounded-time assertion needs a diagnosable failure surface. Proposed fields: `status ('processed'|'failed')`, `attempt_count`, `first_seen_at`, `last_attempt_at`, `processed_at`, `last_error`, with `CHECK ((status='processed') = (processed_at IS NOT NULL))`.

Two mandatory contract amendments if enriching:
1. **Duplicate-detection predicate changes** from "a row exists → skip" to "a row with `status='processed'` exists → skip." A `failed` row must be claimable for retry (upsert with `WHERE consumer_receipt.status <> 'processed'`); side effects performed only when the insert/update took effect. §7's "processed" derivation becomes "receipt exists with status='processed'."
2. **Failure recording is a separate short transaction after rollback** (it cannot survive inside the rolled-back side-effect transaction), with the honest caveat that a crash between rollback and the failure-upsert loses that attempt's record — failure observability is best-effort; success observability remains exact.

Narrowing instead ("successful path inspectable; consumer failures observable only in worker logs") is coherent but contradicts the charter's observability posture and leaves AC-5 failures evidence-free. Not recommended.

---

## Findings

**F1 — Consumer failures leave no inspectable state; "complete path is inspectable" overclaims.**
Severity: **major**. Contract: database-contract.md §4 (consumer_receipt DDL), §6, §7; product-behavior.md §4 step 6, AC-5. Concrete failure: AC-5 automated test with a consumer that throws (poison payload) times out at derived state "published"; the query surface returns identical results to "worker not yet run" — the test fails with no assertable evidence, and no test can detect consumer-attempt failure at all. Owning node: **D**. Resolution: enrich receipt as specified (or, second-best, narrow §7's claim explicitly).

**F2 — `failed` outbox status is outside the three-state model.**
Severity: **major**. Contract: database-contract.md §4 (CHECK allows 'failed'), §5 step 3, §7 derivation table; product-behavior.md §6.4. Concrete failure: a transient Kafka outage exhausts the attempt ceiling → row becomes `failed`; the tester finds the event in none of the three states; AC-5's assertion fails wrongly; no criterion defines recovery from `failed`. Owning node: **D** (one-line P amendment). Resolution: add **failed** as a fourth inspectable state, or contract that the slice's worker retries forever and remove `failed` from the CHECK.

**F3 — No defined join from an interaction to its outbox event; §6.4's joinability requirement is unimplementable.**
Severity: **major**. Contract: product-behavior.md §6.4 ("state must be joinable to the originating interaction"); database-contract.md §4 `outbox_event` (only opaque `payload jsonb`), §2. Concrete failure: the AC-5 test step "verify this submission's outbox event is pending/published" cannot be written — no contract-defined key path from `interaction.id` to an `outbox_event` row. Owning node: **D**. Resolution: add the outbox event id to `audit_event.details`, or add `record_type`/`record_id` columns to `outbox_event`, or require a queryable JSONB path as a D-side invariant.

**F4 — The consumer's business side effect is undefined, making AC-4 unfalsifiable.**
Severity: **major**. Contract: database-contract.md §6 ("its side effects are its own (e.g. reminder or processing records)"); domain-model.md §2.9; product-behavior.md §6.2/AC-4. Concrete failure: the consumer never creates tasks/timeline/contact changes, and no other consumer-produced record type is defined — a tester has nothing to count, so AC-4 passes trivially even with the receipt mechanism completely broken. Owning node: **P** (define the slice consumer's concrete side effect), with D mirroring. Alternative: narrow AC-4 to "exactly one consumer_receipt row per (consumer_name, event_id) after redelivery, and task/timeline/contact counts unchanged" — but say so explicitly.

**F5 — P-AUTH-3b test is physically inexecutable as worded.**
Severity: minor. Contract: product-behavior.md §2 P-AUTH-3b ("remove the user's membership in seed/fixture state") vs domain-model.md §2.3 ("never deleted, only status-revoked") and the composite actor FKs. Concrete failure: after the successful request the test requires, rows referencing membership exist; a fixture DELETE violates FKs and errors. Owning node: **P**. Resolution: reword to "set the membership status to revoked."

**F6 — Timezone-boundary test is vacuous/flaky unless the fixture timezone is chosen dynamically.**
Severity: minor. Contract: product-behavior.md §5.2 test. Concrete failure: with a fixed seeded timezone, the "local dates differ" precondition holds only part of each day; run at other hours the test silently passes vacuously in CI. Owning node: **P**. Resolution: select the timezone at execution time relative to the server clock (UTC+14 / UTC-12 jointly cover every instant). *(Superseded by human ruling: use a seeded non-UTC IANA timezone; test assertions must be made deterministic and non-vacuous at any run time.)*

**F7 — Observation surface for outbox/processing assertions contradicts the "no internal access" preamble.**
Severity: minor (blocker only if Node A never delivers). Contract: product-behavior.md line 7 vs §6.4 (surface owned by Node A, not in this wave) and §5.2's outbox assertion. Concrete failure: AC-5, journey step 6, and 5.2's outbox assertion are executable today only via direct SQL, which the preamble forbids. Owning node: **P**. Resolution: explicit carve-out that processing-state and nothing-created assertions may be made at the database level in integration tests until Node A's surface exists.

**F8 — "Same key, different payload" and concurrent-duplicate behaviors have no mapped test.**
Severity: minor. Contract: database-contract.md §3 (`request_hash` mismatch → client error; concurrent in_progress blocking) — absent from product-behavior.md §5.1 and §7. Concrete failure: an implementation that ignores request_hash (or deadlocks on concurrent same-key submissions) passes every mapped test. Owning node: **P**. Resolution: add both to §5.1.

**F9 — Deactivated-user and suspended-tenant invariants have no test coverage.**
Severity: minor. Contract: domain-model.md §2.1/§2.2 — no corresponding behavior or test in product-behavior.md §2/§7. Concrete failure: both invariants could be unimplemented and all AC tests still pass. Owning node: **P** (add tests) or **D** (demote to future). Resolution: pick one explicitly.

**F10 — The AC-4 redelivery mechanism has no supporting tooling in the topology.**
Severity: minor. Contract: product-behavior.md §6.2; local-topology.md §8 (no consumer-group offset-reset; replay script is a Sprint 0002 deliverable). Concrete failure: the test author has no contracted redelivery mechanism; the three plausible mechanisms exercise different code paths, so "AC-4 passes" means different things per choice. Owning node: **I** (name the tooling), P referencing it.

**F11 — "Tens of seconds" is not an assertable bound.**
Severity: minor. Contract: product-behavior.md §4 step 6 / AC-5. Concrete failure: implementations reaching "processed" in 15 s vs 90 s cannot be objectively distinguished; CI needs a number. Owning node: **P**. Resolution: fix a concrete test timeout.

**Positively verified (no finding):** duplicate-HTTP test (5.1/AC-3) fully specified; worker-restart test (AC-5) executable in the host-process topology modulo F2/F3/F7; cross-tenant test (5.4) decidable including the no-timing-assertion carve-out; AC-1/6/7/8 have concrete UI observation points.

## Verdict

**Not freeze-ready:** F1–F4 must each be resolved (all small, localized contract edits) before the testability claims hold; the rest are minor wording/coverage fixes.
