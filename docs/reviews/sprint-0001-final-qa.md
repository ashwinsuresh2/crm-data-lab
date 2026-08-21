# Sprint 0001 — Final Five-Lens Review: QA Lens

- **Reviewed commit:** `c8b7f11` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** fresh qa-verifier agent instance (read-only)
- **Mechanical checks run:** OpenAPI $ref resolution (42 refs, all resolve, zero orphans); JSON schema parse + required/properties reconciliation (envelope 12/12 closed, payload 10/10 closed); token/title/header/state-name drift sweep across all Wave-2 files.

## AC-by-AC executability (all PASS — every AC has named API observation points)

AC-1 full journey through /v1/me → companies → contacts → interactions → timeline/tasks/audit → processing-status poll (≤30 s). AC-2 constant-body denial classes; outbox-absence stays DB-level per P §6.6 carve-out. AC-3 three automated cases with ID-equality assertions. AC-4 canonical offset reset + receipt/count assertions. AC-5 stop→submit→pending→restart→processed ≤30 s. AC-6/7/8 exact fields and orderings. AC-9 status+body+ordering assertions throughout.

## Findings

**F1 — MAJOR — WAVE2-FIXABLE — api.openapi.yaml CompanyDetail/ContactDetail:** `allOf` over closed bases (`additionalProperties: false`) makes every successful response schema-invalid — `additionalProperties` is evaluated per subschema and cannot see allOf siblings; CompanyDetail was unsatisfiable. Owning node: A. Resolution: flatten (or open the bases). *(Resolved in `a057a15`: flattened final schemas; confirmed by targeted pass + independent validator.)*

**F2 — MAJOR — WAVE2-FIXABLE — api.openapi.yaml ProcessingStatus.consumer/.failure/FailureDetail.secondary:** OpenAPI 3.0 `nullable: true` + `allOf: [$ref]` does not admit null — the mandatory-null responses (consumer before receipt; failure unless failed) were rejected by strict validation. Owning node: A. Resolution: inline nullable objects. *(Resolved in `a057a15`; confirmed.)*

**F3 — MINOR — WAVE2-FIXABLE — event-contract.md §7.2 tier-1:** the cited failed-receipt mechanism (D §6 step-C-shaped UPDATE) is a no-op on first delivery (no receipt row exists). Owning node: E. *(Resolved in `66f597d` via §8.2.1 atomic upsert; confirmed.)*

**F4 — WAVE1-TOUCHING (escalated) — D §3 vs A §6 request-hash scope:** frozen D said body-only; A correctly includes the path contactId (body-only would replay another contact's IDs instead of 409). *(Human-approved Wave-1 amendment `8095d7b` aligned D; targeted pass confirmed no drift.)*

**F5 — INFO — WAVE2-FIXABLE — transient failed vs U's polling stop:** sub-ceiling failed receipts can revert; U froze on failed. *(Resolved in `44095e2`: polling stops at processed only; failed rendered non-latched.)*

**Clean:** envelope required = the 12 mandated fields; payload enum = P's five tokens verbatim; LogInteractionRequest closed with no occurred_at; constant bodies identical between prose and YAML; task titles verbatim in U; header names identical everywhere; topic/consumer names consistent with I §8; all 12 U seam markers and all four U §7 questions resolved by A §12; E's ceilings never contradict D §6.

## Addendum — Independent OpenAPI validation status

**Conclusion (B) at review time:** no standards-aware validator existed on the machine (verified read-only: npx --no-install failures for all candidate CLIs, empty global npm tree, no PATH hits, non-functional Python stubs, no vendored node_modules, no cached Docker validator image; nothing installed). F1/F2 are exactly the defect class such a validator catches and that round-trip/structural checks provably missed. Recommended gate: implementation may not begin until api.openapi.yaml passes an independent validator in a mode that fully resolves $refs and validates schema composability, with zero errors, demonstrably detecting-and-confirming-fixed the two composition defects, plus strict draft 2020-12 compilation of both event schemas. *(Subsequently satisfied pre-freeze via human-authorized temporary tooling — see CONTRACT_FREEZE.md; CI re-run remains a Sprint-0002 gate.)*

## Verdict

Every AC-1..AC-9 assertion executable end-to-end through named API surfaces; F1/F2 were the blocking pre-freeze fixes (both fixed and confirmed).
