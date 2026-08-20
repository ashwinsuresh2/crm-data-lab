# Sprint 0001 — Wave-1 Barrier Review: Data-Correctness Lens

- **Reviewed commit:** `1c4dd59` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** independent qa-verifier agent instance with an adversarial data-correctness brief (read-only)
- **Documents:** docs/specs/database-contract.md (primary), domain-model.md, product-behavior.md §6

---

## Question D — Stale-worker acknowledgment: determination

**The current contract accepts W1's stale ack.** The success-ack predicate in database-contract.md §5 step 3 is:

```sql
UPDATE outbox_event
   SET status = 'published', published_at = now(),
       claimed_by = NULL, lease_expires_at = NULL
 WHERE id = $id AND status = 'pending';
```

There is no ownership term. Interleaving: W1 claims (lease T+30s) → W1 stalls past expiry → W2 re-claims (`claimed_by='W2'`, new lease, `attempt_count++`) and begins publishing → W1 wakes, publishes, issues the ack. The row is still `status='pending'`, so W1's UPDATE matches and commits. Consequences:

1. **Lease clobbered mid-flight.** The row becomes `published` with `claimed_by=NULL` while W2's publish is in flight — falsifying domain-model.md §2.9's `claimed_by` definition ("publisher worker holding the current claim lease") and §7's claim that the lease columns "show an in-flight publish attempt."
2. **W2's ack silently matches 0 rows** (status no longer 'pending'). The contract never specifies worker behavior on a 0-row ack; undefined.
3. **The failure path has no predicate at all.** "Record `last_error` and clear the lease" is prose with no WHERE clause. If stale W1's publish fails and it clears the lease by id, it wipes W2's *active* lease → the row instantly satisfies the claim predicate → W3 claims while W2 is mid-flight. Unbounded concurrent publishers on one row; attempt metadata scrambled.
4. **Worst misstatement:** stale W1 hitting the attempt ceiling may move the row to `'failed'` (predicate-free) while W2's publish succeeded and W2's ack then no-ops. The row is permanently `failed` for an event that was delivered — possibly with a consumer receipt, so inspection simultaneously implies "failed" and "processed."

**Not broken:** no event loss (every success-ack follows a real broker ack, so `status='published'` never lies about delivery); dual publication by W1+W2 is the same envelope with the same `event_id`, absorbed by `consumer_receipt` — the contract consistently frames this as ordinary at-least-once. The corruption is confined to lease/metadata/status attribution, not delivery.

**Fix evaluation:**
- **(b) ownership predicate on `claimed_by` (+ lease):** insufficient as commonly written. `WHERE claimed_by=$worker_id` fails the *same-worker re-claim* case: W1 stalls, its lease expires, W1 itself later re-claims the row in a new batch — a stale ack from attempt N matches attempt N+1's claim. Adding a lease-timestamp equality term turns the timestamp into a de-facto token (workable) but depends on timestamp uniqueness and is easy to implement wrongly.
- **(a) `claim_id` UUID per claim:** unambiguous, clock-free, and gives the failure path the identical guard. **Recommended.**

**Recommended contract amendment (exact semantics), §4 DDL + §5:**
1. Add `claim_id uuid` (nullable) to `outbox_event`.
2. Claim (txn #1): `SET claimed_by=$worker_id, claim_id=gen_random_uuid(), lease_expires_at=now()+$lease, attempt_count=attempt_count+1 ... RETURNING id, seq, claim_id, payload`. Re-claiming an expired row overwrites `claim_id` — the overwrite *is* the revocation of the prior claim.
3. Every post-publish state change carries `WHERE id = $id AND claim_id = $claim_id AND status = 'pending'` — success, failure, and failed-ceiling transitions alike.
4. **0 rows updated ⇒ the worker lost the lease; it MUST take no further action on that row.** Any publish already performed is ordinary at-least-once duplication, absorbed by consumer receipts.

*(Human ruling 2026-08-20: ratified; `claimed_by` retained for observability only.)*

---

## Findings

**F1 — Stale-worker ack accepted; ack/failure predicates lack claim ownership.**
Severity: **major** (no event loss, but the contract's own lease invariants and inspection surface are falsifiable; permanent failed-though-delivered is reachable). Contract: database-contract.md §5 steps 1/3, §4 DDL; domain-model.md §2.9. Failure example: interleavings 1–4 above. Owning node: **D**. Resolution: the claim_id amendment, plus an explicit sentence defining 0-row-ack as "lease lost, stop."

**F2 — §7 state derivation is ambiguous: "pending" and "processed" are not mutually exclusive.**
Severity: **major**. Contract: database-contract.md §7 table; domain-model.md §2.9 last invariant; product-behavior.md §6.4. Failure example: W1 claims, publishes, crashes before ack (row stays `pending`); the consumer processes the event and commits a receipt. During this entirely-normal at-least-once window the row satisfies both the "pending" derivation and the "processed" derivation — only "published" carries the no-receipt clause. An inspection surface built literally from this table reports one event in two states; AC-5's "pending/published but not processed" assertion is ill-defined. Owning node: **D** (P for §6.4 wording). Resolution: explicit precedence — processed ⇔ receipt exists; published ⇔ status='published' AND no receipt; pending ⇔ status='pending' AND no receipt.

**F3 — §7 "pending" gloss is dishonest in the crash window.**
Severity: minor. Contract: database-contract.md §7 row 1 ("not yet acknowledged by Kafka"); product-behavior.md §6.4. Failure example: crash after broker ack, before ack txn — row is `pending` yet the event *was* acknowledged and may already be consumed. Owning node: **D** (P for §6.4). Resolution: "not yet *confirmed* published; may already be in the event stream (at-least-once)."

**F4 — `failed` status has no mapping in the three-state inspection taxonomy.**
Severity: minor. Contract: database-contract.md §7 vs §4 CHECK; product-behavior.md §6.4. Failure example: a row moved to `failed` at the attempt ceiling is inspectable as none of pending/published/processed. Owning node: **D** + **P**. Resolution: add a fourth operator-visible state or map failed explicitly.

**F5 — Envelope `event_id` = `outbox_event.id` is assumed, never pinned.**
Severity: minor. Contract: database-contract.md §4 (`consumer_receipt.event_id` — "stable event ID from the envelope (Node E)") and §7 processed-join; product-behavior.md §6.4 joinability. Failure example: if Node E mints its own envelope id distinct from `outbox_event.id`, the §7 "processed" derivation and the joinability requirement have no join key (payload is opaque jsonb). Duplicate absorption still works; inspection breaks. Owning node: **D** (seam with E). Resolution: one sentence — "the envelope's `event_id` MUST equal `outbox_event.id`."

**F6 — Consumer "atomic with side effects" holds only for DB-internal side effects.**
Severity: minor. Contract: database-contract.md §6. True *in this slice* only because product-behavior.md §6.5 forbids external side effects; the text would silently overclaim exactly-once the day a consumer adds any non-DB effect (email, HTTP call), which cannot join the receipt transaction. Owning node: **D**. Resolution: explicit caveat scoping the atomicity guarantee to transactional (PostgreSQL) side effects; external effects require a separate pattern and a decision record.

**F7 — Backstop index covers only half of AC-3.**
Severity: minor. Contract: database-contract.md §3 last paragraph, §9 AC-3 row, §4 `task_one_per_interaction_uq`. The partial unique index prevents a second task *for the same interaction* — but if a future retry path mishandles the key protocol, the actual failure is **two interactions, each with one task** — different interaction_ids, index never fires. The "one interaction" half of AC-3 rests entirely on the idempotency-key primary key; §9's citation of the index overstates its coverage. Owning node: **D**. Resolution: reword to state the backstop covers task-per-interaction uniqueness only.

**Verified correct (adversarially checked, no finding):**
1. The idempotency-key row is inside the same transaction as writes (1)–(6): a crash between claim and commit leaves no orphan `in_progress` row — the §3 claim is accurate.
2. The described `ON CONFLICT DO NOTHING` blocking behavior (second inserter waits on the in-flight conflicting transaction, then re-evaluates: commit → 0 rows/replay, abort → insert proceeds) is exactly PostgreSQL's speculative-insertion semantics under READ COMMITTED; since step (6) sets `completed` pre-commit, a committed key row is always `completed` — no interleaving of two duplicates yields two interactions, two tasks, or an observable committed `in_progress`.
3. The §5 ordering caveat is honest — nothing asserts gap-free or commit-ordered `seq`, and `GREATEST` makes `last_contacted_at` forward-only under out-of-order commits.
4. Dual publication (W1+W2) is consistently treated as ordinary at-least-once across all three documents.

## Verdict

**Not freeze-ready as written; freeze-ready after two amendments** — claim-ownership (`claim_id`) predicates on §5's transitions (F1) and a mutually exclusive §7 derivation with defined precedence (F2); F3–F7 are one-sentence wording pins that should ride along.
