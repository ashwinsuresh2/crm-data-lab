# Sprint 0001 — Wave-1 Upstream-Contract Freeze

**Status:** Wave-1 upstream contracts frozen. This is NOT the final Sprint-0001 contract freeze — that gate (`CONTRACT_FREEZE.md` + ADR-0001..0003) occurs only after Wave 2 (Nodes A, E, U) merges and passes the final independent five-lens review.

**Date:** 2026-08-20
**Frozen contract commit:** `0838854` on `sprint-0001-contracts`
**Frozen files:**
- `docs/specs/product-behavior.md` (Node P — final micro-fix `4d3ca94`)
- `docs/specs/domain-model.md`, `docs/specs/database-contract.md` (Node D — final micro-fix `a3f3a0e`)
- `docs/specs/local-topology.md` (Node I — final micro-fix `125a9b1`)

## Review provenance

- Barrier review (5 lenses): `docs/reviews/sprint-0001-barrier-*.md` at `1c4dd59`.
- Human barrier rulings applied via one remediation pass (commits `57967a2`, `71036e9`, `de954c4`, merged at `87efe3f`).
- Confirmation pass (5 fresh lenses): `docs/reviews/sprint-0001-confirmation-*.md` — unanimous freeze, zero unresolved majors.
- Human-authorized bounded micro-fix batch (5 exact items) merged at `0838854`.
- Targeted confirmation (4 lenses, pass/reject only): **4× PASS** — zero-row receipt finalization (data-correctness), `seq` confidentiality + withTenantWrite obligation (security), both-stages-failed tie-break (product/QA), P-AUTH-8 single-source denial-log reference (architecture).

Wave-1 contracts may not be modified except under a new human-approved bounded loop. Wave-2 nodes treat them as frozen inputs; conflicts route to the lead, never edited in place by Wave-2 nodes.

## Human-approved Wave-1 amendment (2026-08-20, ruled at the final freeze gate)

- **Prior frozen commit:** `0838854`
- **Amendment commit:** `8095d7b` (Node D, `docs/specs/database-contract.md` only), merged into `sprint-0001-contracts` at `af32c62`.
- **Exact reasons (both ruled by the human after the final five-lens review):**
  1. **Request-hash scope correction (§3):** the body-only `request_hash` definition was replaced with: "The request hash covers the canonical semantic request: all relevant tenant-scoped path identifiers, including contactId for log-interaction, plus the normalized request body. Server-generated fields such as occurred_at are excluded." Under body-only hashing, the same scoped key with the same body against a different contact would replay another contact's IDs instead of returning `409 idempotency_key_conflict`; Node A's API contract already stated the correct rule, and this aligns the frozen source.
  2. **`attempt_count` in RETURNING lists (§5, §6):** the post-increment `attempt_count` was added to the illustrative RETURNING lists of the outbox claim operation and the consumer attempt-start operation, because Node E's retry ceilings are keyed on values those statements previously did not surface. The attempt policy itself is unchanged; ceilings remain Node E's.

No other Wave-1 file changed; product behavior, domain objects, and local topology are untouched.

## Wave-2 obligations (recorded now, implemented later)

### Obligation 1 — withTenantWrite enforcement (mandatory Sprint-0002 implementation gate)

- Every tenant-owned mutation must execute through the shared `withTenantWrite` helper.
- Raw tenant-write transaction access is not exported to endpoint modules.
- Automated tests must prove every mutation path performs the in-transaction `FOR SHARE` membership recheck.

### Obligation 2 — Node E: last_error hygiene (carried into Node E's packet)

- `last_error` is bounded and sanitized.
- It contains an error code and a safe operator-facing summary.
- It must not contain credentials, dev tokens, raw event payloads, email bodies, notes, or other sensitive CRM content.
- Detailed exceptions belong in protected process logs.
- This is mandatory before any non-local deployment.

### Obligation 3 — Node A: browser inspection surface (carried into Node A's packet)

- Define the authenticated, active-tenant-scoped event-processing inspection endpoint.
- Use cross-tenant not-found semantics.
- Expose enough information for the browser journey to observe pending, published, processed, and failed.
- This endpoint closes the deferred browser-only portion of AC-1 journey step 6.

## What remains for Sprint 0001

1. Wave 2: Node A (`docs/specs/api-contract.md`, `docs/specs/api.openapi.yaml`), Node E (`docs/specs/event-contract.md`, `docs/specs/schemas/event-envelope.v1.schema.json`, `docs/specs/schemas/interaction-logged.v1.schema.json`), Node U (`docs/specs/ux-architecture.md`) — separate worktrees branched from this freeze.
2. Merge A/E/U into `sprint-0001-contracts`; complete cross-contract mechanical checks.
3. Final independent five-lens review over all Wave-1 + Wave-2 contracts; blocking findings resolved only under a separately approved bounded loop.
4. Only then: final `CONTRACT_FREEZE.md`, ADR-0001..0003, and the true Sprint-0001 human freeze gate. No PR to `main`, no push, until that gate passes.
