# Sprint 0001 — Confirmation Pass: QA Lens

- **Reviewed commit:** `87efe3f` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** fresh qa-verifier agent instance (read-only; independent of prior passes)
- **Prior review:** docs/reviews/sprint-0001-barrier-qa.md

## Per-item verdicts

1. **F1 receipt enrichment — PASS.** database-contract §4 DDL: `status CHECK (IN ('processing','processed','failed'))`, `attempt_count`, `first_seen_at`, `last_attempt_at`, `processed_at`, `last_error`, `CHECK ((status='processed') = (processed_at IS NOT NULL))`, composite tenant FK. §6 skip rule: duplicates skipped only when `status='processed'`; failed retryable; processing re-attempted. Three-transaction lifecycle (A: attempt-start upsert with `<> 'processed'` guard; B: processed atomic with side effects, guarded `status='processing'`, 0 rows → ROLLBACK then ack; C: post-rollback failure recording explicitly BEST-EFFORT with the crash-window caveat). Coherence verified by interleaving analysis: concurrent duplicates converge; `first_seen_at` preserved on conflict; the CHECK holds in every transition.
2. **F2 failed as fourth state — PASS.** §7.1 precedence table processed → failed → published → pending, mutually exclusive by first-match evaluation; failure_stage with per-stage last_error; both-failed tie-break to publication. product-behavior §6.4 matches condition-by-condition — no derivation drift. domain-model §2.9 mirrors.
3. **F3 outbox linkage — PASS.** `event_type`/`aggregate_type`/`aggregate_id`/`aggregate_version` columns + aggregate index; interaction.logged mapping (aggregate_type='interaction', aggregate_id=$interaction_id, version 1); envelope event_id = outbox_event.id pinned; §7.2 full Interaction → outbox_event → consumer_receipt SQL join.
4. **F4 falsifiable AC-4 — PASS.** Receipt defined as the consumer's entire side effect in all three contracts; AC-4 rewritten to "exactly one processing receipt + no duplicate downstream record" — now decidable (a broken receipt mechanism yields receipt count ≠ 1 or attempt-visible re-execution).
5. **Prior minors — PASS (all).** Revoke wording (no residual "remove-membership"); seeded `Pacific/Kiritimati` test with runtime-computed today/yesterday assertions, decidable at every hour, date-divergence assertions forbidden (by-design note: the reject-yesterday case discriminates a server-timezone implementation only during divergence hours — consequence of the ruling, not a finding); §6.6 carve-out reconciled with the preamble; request-hash + simultaneous-duplicate in §5.1/AC-3 (i)–(iii); canonical redelivery tooling (`kafka-consumer-groups.sh --reset-offsets --to-earliest`) named in local-topology §8 with rationale, consistent with product-behavior §6.2; 30 seconds everywhere ("tens of seconds": zero remaining); P-AUTH-6/7 tester procedures with AC-9 mandating automation.
6. **Testability regression sweep — PASS.** Every §7 criterion (AC-1..AC-9), §5.1–5.7, §6.1–6.6, P-AUTH-2–8, and the ordering-pipeline test each have a defined observation point (UI, API, or §6.6 DB carve-out) and a decidable assertion. The rewrite introduced no blocking ambiguity.

## Findings (minor residue only — no unresolved major, no regression)

1. **Minor** — product-behavior §6.4 omits the both-stages-failed tie-break (database-contract §7.1: report `publication` first). Not derivation drift, but a tester asserting failure_stage in the double-failure case must consult D's contract. Owning node: P. Resolution: mirror the tie-break sentence.
2. **Minor** — Denial-log field drift: P-AUTH-8 requires "actor claim, tenant, route, timestamp"; local-topology §7 says "actor, tenant, action, record, and time." A log-assertion test written against topology's list would miss "route". Owning node: I (align to P-AUTH-8, which is authoritative).
3. **Cosmetic** — database-contract §6 transaction B comment "0 rows updated → a concurrent attempt already processed it" is imprecise: 0 rows can also mean a concurrent attempt marked it failed. The prescribed action is safe in both cases; no behavioral defect. (See the data-correctness confirmation's R1 for the full treatment.)
4. **Note (by design)** — AC-1's "entirely in the browser" cannot cover journey step 6 until Node A's inspection surface ships; §6.6 bridges this per the ruling. Re-check when Node A lands.

## Verdict

**Freeze-ready** — all four prior majors and all prior minors resolved per the rulings with no new regression; only cosmetic wording residue remains, none of which blocks writing or executing any acceptance test.
