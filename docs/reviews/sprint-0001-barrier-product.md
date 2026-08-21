# Sprint 0001 — Wave-1 Barrier Review: Product Lens

- **Reviewed commit:** `1c4dd59` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** independent product-spec agent instance (read-only)
- **Documents:** docs/specs/product-behavior.md (primary), domain-model.md, database-contract.md, local-topology.md, docs/FIRST_VERTICAL_SLICE.md

---

## Question A — `not_interested` vs. the mandatory follow-up Task

**HUMAN DECISION REQUIRED** (analysis only; decided by the human after this review — see ruling appendix).

The tension: product-behavior.md §1 defines `not_interested` = "Spoke with the contact; they declined further engagement," yet §3.4 requires a follow-up date "on or after today" on every submission, and the journey invariant (§4) plus domain-model §2.6 mandate exactly one open Task per Interaction. So declining further engagement forcibly schedules further engagement. Aggravating factor: §8 states tasks "are created open and stay open in this slice" — the not-interested task can never be cleared and sits on Home indefinitely.

### Option 1 — Remove or replace `not_interested` in Sprint 0001
One-line edits in product-behavior.md §1/§3.4; D untouched (vocabulary defers to P; DB constrains presence/length only). **Cost:** the first user is the founder doing real calls; "not interested" is one of the most frequent real outcomes of a cold call. Removing it forces miscategorization (`connected` + a note), corrupting outcome data from day one. Cheapest edit, worst product fidelity.

### Option 2 — Keep it; the resulting Task is a close-out/re-engagement action
Nothing structural changes: invariant, transaction (database-contract §2), idempotency contract (§3, `task_id NOT NULL` on completed rows), and AC-3/AC-7 stand. Product framing: *no prospect leaves a call without a recorded next action; for a declined prospect the next action is a deliberate disposition* — close-out review or re-engagement check ("revisit in 6 months"). On Home the task shows contact, company, due date, and outcome `Not interested`, self-explanatory as a re-engagement/close-out reminder. **Cost:** one extra required decision (a date) at disqualification; one clarifying paragraph in §1/§3.4.

### Option 3 — Allow terminal outcomes to omit the Task
Ripple inventory:
- **FIRST_VERTICAL_SLICE.md itself:** the user story says "creates exactly one task" and AC-3 says a duplicate request "produces one interaction and one task." Option 3 contradicts the frozen scope document — beyond what any node can decide.
- **product-behavior.md:** §1, §3.4 (conditional validation branch, new invalid-input classes), §4 step 5 and the journey invariant, §5.1 test assertions, §5.2, AC-3, AC-7, §7's ID-return check.
- **domain-model.md:** §2.6 invariant becomes conditional; §2.7 exactly-one becomes at-most-one; write set becomes 4-or-5; new "terminal outcome" concept needs an owner.
- **database-contract.md:** §2 step (3) conditional; §3 `task_id` non-null CHECK relaxed — a structural proof weakened to application-level; §9 traceability changes.
- **Test surface roughly doubles** for the log-interaction path.

### Recommendation
**Option 2.** (a) Option 3 contradicts the frozen slice scope and dilutes the exactly-one-task invariant the correctness apparatus exists to prove; (b) Option 1 deletes the most common real outcome and degrades data quality; (c) Option 2 costs one paragraph and defers "terminal outcomes close without a task" to the sprint that introduces task lifecycle. If approved, resolve Finding F3 (task title) in the same edit.

---

## Findings

**F1 — The consumer's business side effect is undefined, making AC-4 untestable as written.**
- Severity: **major**
- Contract/section: product-behavior.md §6.2/§6.4/§6.5; domain-model.md §2.9 ("e.g. reminder/processing records"); database-contract.md §6; FIRST_VERTICAL_SLICE.md async #3.
- Concrete failure: a tester implementing AC-4 must assert "no duplicate business side effect" after forced redelivery — but no contract says what the consumer's first-delivery side effect is. If it is only the `consumer_receipt` row, the test degenerates to "receipt count = 1"; if a "reminder record" exists, it is a noun never defined in §1. Two implementers will build different consumers and different tests.
- Owning node: **P** (declare the observable contract), with D/E aligning.
- Resolution: state explicitly either "the consumer's only effect is the processing receipt; 'processed' state *is* the side effect" or define the reminder record as a tenth noun.

**F2 — Outbox `failed` state has no product-visible representation.**
- Severity: minor
- Contract/section: product-behavior.md §6.4 (enumerates exactly pending/published/processed); database-contract.md §4/§5/§7 (`status = 'failed'` exists; §7 has no row for it).
- Concrete failure: Kafka stays down past the attempt ceiling; the row moves to `failed`. The tester finds an event in none of the three enumerated states; §4 step 6 fails with no defined observable explanation.
- Owning node: **P** (add "failed" as a fourth inspectable state) or **D/E** (remove `failed` from the slice).
- Resolution: pick one; align §6.4 and database-contract §7.

**F3 — `Task.title` is required and NOT NULL but never defined or displayed by the product.**
- Severity: minor
- Contract/section: domain-model.md §2.7; database-contract.md §4 (`title text NOT NULL`); product-behavior.md §3.1 (Home shows contact, company, due date, outcome — no title).
- Concrete failure: the implementer must generate a title with no owning spec; implementations produce different stored text; no acceptance test can check it. If Option 2 is chosen, title content for `not_interested` matters and is unowned.
- Owning node: **P** — define the generation rule or declare title out of the product surface.

**F4 — Contact `email`/`phone` exist in the domain model but have no product behavior.**
- Severity: minor
- Contract/section: domain-model.md §2.5, database-contract.md §4 vs. product-behavior.md §1/§3.2/§4.
- Concrete failure: a tester cannot determine whether the create-contact form has email/phone fields; adding them widens scope silently, omitting them may be flagged against the domain model.
- Owning node: **P** — state explicitly whether email/phone are capturable/visible in this slice.

**F5 — Home ordering has no tie-breaker.**
- Severity: minor
- Contract/section: product-behavior.md §3.1 ("ordered by due date ascending").
- Concrete failure: two tasks due the same day render nondeterministically; an ordering test flakes.
- Owning node: **P**. Resolution: deterministic secondary key (creation time, then id).

**F6 — P-AUTH-3b test wording contradicts the never-delete-membership invariant.**
- Severity: minor
- Contract/section: product-behavior.md §2 P-AUTH-3b ("remove the user's membership") vs. domain-model.md §2.3 ("never deleted, only status-revoked"; deletion breaks composite actor FKs).
- Concrete failure: a test author issues DELETE on membership, hits FK violations from existing audit/created_by rows — the test fails for the wrong reason.
- Owning node: **P**. Resolution: reword to "revoke the membership (status → revoked)".

**F7 — Company-creation surface and company list are not in the screen inventory.**
- Severity: minor
- Contract/section: product-behavior.md §3 (five screens) vs. §3.2, §3.1 empty state, §4 step 2.
- Concrete failure: AC-1 requires the journey "entirely in the browser," but no screen says where company creation lives or what the list shows per row; the AC-1 test script cannot be written unambiguously.
- Owning node: **P**. Resolution: add a sixth screen or fold both into an existing screen's definition.

**F8 — Domain model adds identity behaviors (suspended tenant, deactivated user) absent from the product contract.**
- Severity: minor
- Contract/section: domain-model.md §2.1, §2.2 vs. product-behavior.md §2/§8.
- Concrete failure: a reviewer cannot tell whether these are slice requirements needing tests or dormant seams.
- Owning node: **D** (mark as non-slice seams) or **P** (adopt as P-AUTH rules). Either closes the gap.

**No cross-contract drift found on:** multi-tenant membership behavior, the timezone rule, vocabulary ownership, the not-found cross-tenant posture, and the topology (host-run worker enables the kill test; `/readyz` not gated on Kafka matches §6.1; loopback-only and the dev-token env guard support P-AUTH-5; $0 cost floor).

## Verdict

Freeze-ready apart from Question A (human decision) and one major clarification (F1), with six minor fixes that can land in the same remediation pass.

---

## Appendix — Human ruling (2026-08-20, post-review)

Option 2 chosen with clarifications: stored token `not_interested` kept with visible label "Not interested now"; product-wide rename of "follow-up task/date" to "next-action task/date"; the `not_interested` task is "Review disposition: close out or set a re-engagement date."; Node P owns deterministic Task-title behavior for every seeded outcome.
