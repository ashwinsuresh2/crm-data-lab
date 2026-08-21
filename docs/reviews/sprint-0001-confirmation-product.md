# Sprint 0001 — Confirmation Pass: Product Lens

- **Reviewed commit:** `87efe3f` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** fresh product-spec agent instance (read-only; independent of the barrier-review and remediation instances)
- **Prior review:** docs/reviews/sprint-0001-barrier-product.md

## Per-item verdicts

1. **Ruling A — PASS.** Token `not_interested` kept with label "Not interested now" (§1 outcome table); product-wide next-action rename with "follow-up" surviving only in the preamble mapping statement, the §7 preamble, and AC-7's preserved source quote; the one-task-per-interaction invariant intact (§1, §4 journey invariant, AC-7); deterministic titles for all five outcomes with `not_interested` exactly "Review disposition: close out or set a re-engagement date.", mirrored in domain-model §2.7 and database-contract §2 step 4.
2. **Consumer side effect + AC-4 — PASS.** §6.5: the receipt IS the entire side effect (no Task, Contact change, notification, or external call); AC-4/§6.2: exactly one processing receipt plus unchanged task/timeline/contact counts. Matches database-contract §6 in substance.
3. **Four states with precedence — PASS.** §6.4: processed → failed → published → pending (pending includes active publication lease); failure_stage (publication|consumer) and last error exposed. Identical to database-contract §7.1.
4. **Inspection-surface security — PASS.** §6.4: same authentication, active-tenant Membership resolution, authorization, tenant scoping, and §5.4 cross-tenant not-found as every endpoint, with a concrete cross-tenant test; wired into AC-9.
5. **Prior minors — PASS (all).** Optional email/phone (§1, §3.3, §3.4 with test); dedicated Companies screen (§3.2, six-screen inventory); Home tie-breaker (due date → creation date-time → task ID, seeded-tie test); "revoke" wording everywhere; P-AUTH-6/7 with tester procedures including reactivation and prior-records-visible checks; seeded `Pacific/Kiritimati` timezone test with runtime-computed assertions non-vacuous at any hour; request-hash-mismatch + concurrent-duplicate mapped in AC-3; 30-second bound; §6.6 DB-level carve-out; P-AUTH-8 denial logging with rate limiting as explicit future requirement.
6. **Human corrections — PASS (all three exact).** §6 intro character-exact ("The observable contract for the asynchronous path—from a committed Outbox event through publication and processing—is:"); case-insensitive "Kafka" search: zero matches; §7 heading exactly "Source acceptance criterion / product rendering".
7. **Cross-contract consistency — PASS.** D mirrors the renames, token/label ruling, recheck ownership split, receipt-only side effect; P matches I on killable host worker, non-Kafka-gated readiness, multi-factor dev-token guard. AC-4's cite-by-position is correct against FIRST_VERTICAL_SLICE.md; all other AC quotes verbatim.
8. **Regression sweep — PASS.** No dangling references; nine-object claim consistent; every remediation-introduced noun defined; all acceptance criteria remain procedure + assertable outcome; §8 non-goals coherent.

## Findings

**R1 — Stale field-table note in the domain model contradicts the ratified suspended-tenant behavior.**
- Severity: minor residue (not an unresolved major; not in P's file).
- Contract/section: domain-model.md §2.1, Tenant `status` row: "Slice only uses `active`."
- Concrete failure: P-AUTH-6's test requires seeding a suspended tenant and later reactivating it, so the slice demonstrably uses both statuses. D's own invariant paragraph below the table already acknowledges this — the note is leftover internal inconsistency; a literal reader could conclude no suspended fixture is needed.
- Owning node: D.
- Recommended resolution: amend to "Both values exercised in the slice (suspended only via fixtures, per Node P's P-AUTH-6)."

## Verdict

**FREEZE** — the product behavior contract at 87efe3f correctly implements all human rulings and prior-finding remediations with no product-side regressions; the single minor residue (R1) is a one-line domain-model wording fix that does not block the freeze.
