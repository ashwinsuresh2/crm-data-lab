# Sprint 0001 — Final Five-Lens Review: Data-Correctness Lens

- **Reviewed commit:** `c8b7f11` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** fresh qa-verifier agent instance with adversarial data-correctness brief (read-only)

## Verification summary

1. **E retry/dead-letter vs D §5/§6 — CONSISTENT** (one seam gap, F1). Attempt-counting-as-claims acceptable; deterministic-failure immediate-terminal transitions carry the claim_id guard (E imports D's protocol verbatim). Consumer crash walks all HOLD: crash after processed-receipt before offset commit → redelivery skips-and-acks (processed absorbing); crash after park before offset commit → one extra harmless attempt; crash mid-seek-back → resume from committed offset, no loss. Park-at-ceiling reconciles with "failed stays retryable" (attempt-start has no ceiling precondition; operator redelivery always gets one fresh attempt).
2. **Tier-2 unattributable handling — honest, no wedge:** commits the offset and continues, stated openly; detection signal (stuck-published past the 30 s bound) and recovery (replay from the never-deleted outbox) named. INFO: such events rest permanently at `published` with consumer null — manual monitoring in the slice.
3. **A's idempotency-binding rule — verified as a pure restatement of D §3** + the pipeline order (validation precedes the transaction; the key row rolls back with it). No interleaving of a validation-failing and a succeeding same-key request violates the stated semantics. Deliberate precedence recorded: invalid + hash-mismatched → 400, never 409.
4. **Inspection derivation matches D §7.1 exactly** (precedence, tie-break, confidentiality); 30 s bound satisfiable on the healthy path (low single-digit seconds); corner: lease length (F5).
5. **Schema pedantry:** required+nullable `causation_id` construction correct; event_id uuid ↔ outbox uuid matches; strictness intact. F3 (formats non-asserting by default), F4 (equalities description-only).
6. **Ordering claims — no falsifiable claim found** (seq never on the wire; U renders as delivered from server-clock orders with unique-id tiebreaks; processed is absorbing, no state regression derivable).

## Findings

**F1 — LOW — WAVE1-TOUCHING (escalated):** E's ceilings key on attempt_count values D's frozen RETURNING lists did not surface (claim: `RETURNING id, seq, payload, claim_id`; attempt-start: `RETURNING status`). *(Human-approved Wave-1 amendment `8095d7b` added post-increment attempt_count to both lists; policy stays E's; confirmed.)*

**F2 — MEDIUM — WAVE2-FIXABLE:** tier-1 park cannot create the receipt it promises — "D §6 step C shape" is an UPDATE guarded on status='processing' matching zero rows when no receipt exists; a fresh tier-1-invalid message would produce no failed receipt, commit the offset, and rest at `published` forever, contradicting E's own guarantees and §10's test. Owning: E. *(Resolved in `66f597d` via the §8.2.1 atomic INSERT...ON CONFLICT...DO UPDATE with offset-commit-only-after-receipt; all three interleavings re-walked and confirmed.)*

**F3 — MEDIUM — WAVE2-FIXABLE:** all identity/time constraints rested on `format`, non-asserting by default in draft 2020-12 — `event_id: "banana"` passed a spec-compliant validator in annotation mode. Owning: E. *(Resolved in `66f597d` §3.4: normative format-assertion requirement + negative fixtures; independently validated.)*

**F4 — LOW — WAVE2-FIXABLE:** envelope↔payload equalities were description-only and undetectable by the specified validation. *(Resolved: added to §6.2's asserted checklist with EVENT_LINKAGE_MISMATCH.)*

**F5 — LOW — WAVE2-FIXABLE:** AC-5's 30 s restart bound breachable by the illustrative 30 s publication lease (kill-after-claim → unclaimable ~29 s). *(Resolved: default lease pinned 10 s; AC-5 clock defined as starting at worker restart.)*

**F6 — INFO:** textual tension between D §6's "do not acknowledge" and E's park-offset-commit. *(Resolved: §7.3 clarifies the offset commit on park is transport-level, not the forbidden success acknowledgment.)*

**F7 (addendum) — LOW — WAVE2-FIXABLE:** "byte-for-byte" replay unkeepable (jsonb; no original bytes exist anywhere post-commit; even first publication re-serializes). No downstream guarantee depends on bytes (receipts key on event_id; validation logical; partitioning by value). Offset-reset vs replay distinction otherwise correctly drawn; §2.2 "reconstruct" over-claimed twice (bytes and order). *(Resolved in `66f597d`; confirmed.)*

**Addendum A2 — schema/prose agreement: full agreement** on event_type, schema_version semantics, causation_id present-but-null, notes exclusion (INFO: was schema-description-only; now also contract prose), outcome enum (P's five tokens verbatim), and formats — subject to F3/F4, both resolved.

**Adversarially verified clean:** idempotency reservation in-transaction (no orphan in_progress row); ON CONFLICT blocking semantics = PostgreSQL speculative insertion; §5 ordering caveat honest; dual publication consistently at-least-once.

## Verdict

PASS WITH FINDINGS — every frozen invariant (at-least-once + receipt dedupe, claim_id ownership, idempotency binding, four-state precedence, seq confidentiality) held under all crash/duplicate/redelivery interleavings examined; F2 and F3 were the gating fixes (applied and confirmed), F1 resolved by the human-approved Wave-1 amendment.
