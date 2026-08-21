# Sprint 0001 — Final Five-Lens Review: Security Lens

- **Reviewed commit:** `c8b7f11` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** fresh security-reviewer agent instance (read-only)

## Verification summary

1. **Node A auth pipeline — VERIFIED.** X-Dev-Token as a removable seam; fixed testable pipeline order (auth precedes validation, so unauthenticated probes harvest no validation feedback); 401 constant for unknown token AND deactivated user (no account-status leak); 403 one generic constant; full-inventory constant-body 404 walk — **no endpoint found where an ID probe distinguishes existence** (tenant-scoped lookup ordered before body validation and before the idempotency-key read, so cross-tenant+invalid-body / missing-key / bound-key probes all collapse to the same 404). /livez and /readyz are the only endpoints outside the pipeline; neither returns tenant data.
2. **Inspection endpoint (Obligation 3) — VERIFIED.** Identical pipeline, active-tenant scope, cross-tenant 404; seq/claim_id/claimed_by/lease_expires_at/payload occur only in comments/descriptions, never as schema properties; ProcessingStatus subtree closed.
3. **Idempotency — VERIFIED, no D §3 contradiction.** Scope (tenant, actor, operation, key) means a foreign actor's identical key string is a fresh key; A's binding rule is the direct consequence of D's in-transaction reservation rolling back; 409 body is constant, one bit to the same actor about their own request. No replay/enumeration vector.
4. **Node E — VERIFIED** (one seam finding, F1). Partition key tenant_id with per-tenant-only guarantees; **payload data minimization commendable** (no notes, no contact PII in the stream); Obligation 2 carried with closed code list; replay side-effect-free with composite receipt FK making tenant mis-attribution a constraint violation; tier-2 unattributable handling logs sanitized structure only.
5. **Node U — VERIFIED.** Internal fields banned from rendering/console/URLs; one generic not-found presentation; tokens never in URLs or client logs; no flow bypasses the API.
6. **WAVE1_FREEZE Obligations 1–3** — correctly carried (1), discharged at contract level (2, tightened by F1), fully discharged (3).

## Findings

**F1 — MEDIUM — WAVE2-FIXABLE — Kafka offset inside tenant-visible last_error recreates the banned global-counter leak.** E §9 rule 1 listed topic/partition/offset as safe scalars; A §9 surfaces last_error verbatim; on the shared single partition the offset is a global monotone counter — the exact leak class D §7.1 bans for seq, reintroduced through string composition (abuse: sampling failures over time yields other tenants' aggregate activity). Owning node: E (A defense-in-depth). Resolution: remove offset/partition/topic from the safe-scalar list; confine to protected logs; add digits to the negative-assertion test list. *(Resolved in `66f597d` + `a057a15`; three-layer targeted confirmation PASS.)*

**F2 — LOW — WAVE2-FIXABLE — U classified deactivated user (P-AUTH-7) under the 403 class while A deliberately returns 401** (so the response cannot reveal the token was once valid). No actual leak, but the misclassification invites an implementer to build a distinguishing signal. Owning node: U. *(Resolved in `44095e2`.)*

**F3 — LOW — WAVE2-FIXABLE — consumer seek-back retry blocks all tenants on the shared partition** (cross-tenant head-of-line blocking unnamed; not recorded as a pre-exposure requirement). Owning node: E. *(Resolved in `66f597d`: named as accepted slice-scale risk + pre-exposure fairness requirement.)*

**Informational:** unauthenticated /readyz may report Kafka status (frozen I §7) — safe within the loopback trust boundary; pre-exposure checklist item. Rate-limiting absence properly documented as a pre-exposure gate.

## Verdict

PASS — the Wave-2 contracts discharge or carry all three freeze obligations, enforce cross-tenant ≡ nonexistent constant-body 404 everywhere with no distinguishing probe, mechanically exclude internal outbox/lease fields, and minimize event-stream data; the offset-in-last_error seam was the one substantive issue (fixed and confirmed pre-freeze).
