# Sprint 0001 — Contract Freeze

**Status:** All seven Sprint-0001 contracts frozen, pending the human freeze-gate approval that this document is presented at. Freeze scope: `docs/specs/` in its entirety (four Wave-1 contracts, three Wave-2 contracts, two machine-readable event schemas, WAVE1_FREEZE.md, this document).

**Date:** 2026-08-20
**Branch:** `sprint-0001-contracts` (never pushed; `main` untouched)

## Final authoritative commits

| Artifact | Final commit |
|---|---|
| Contract state confirmed by the targeted confirmation pass | `df2ebb8` |
| Node P — product-behavior.md | `4d3ca94` (branch `agent/sprint-0001-product`) |
| Node D — domain-model.md, database-contract.md | `8095d7b` (incl. the human-approved Wave-1 amendment) |
| Node I — local-topology.md | `125a9b1` |
| Node A — api-contract.md, api.openapi.yaml | `a057a15` |
| Node E — event-contract.md, schemas/*.v1.schema.json | `66f597d` |
| Node U — ux-architecture.md | `44095e2` |
| Wave-1 upstream freeze record | `WAVE1_FREEZE.md` (frozen `0838854`; amendment recorded at `df2ebb8`) |

## Review provenance

1. Wave-1: barrier review (5 lenses) → human rulings → remediation → confirmation (5 fresh lenses, unanimous) → micro-fix batch → targeted confirmation (4× PASS) → upstream freeze (`WAVE1_FREEZE.md`).
2. Wave-2: Nodes A/E/U authored against the frozen Wave-1 inputs in isolated worktrees.
3. Final five-lens review over all contracts (`docs/reviews/sprint-0001-final-*.md`) + human addendum (replay identity, strict schema integrity, independent-validation status).
4. Human-authorized bounded remediation loop (A1–A4, E1–E5, U×5, D amendment) — one commit per node, scope-verified.
5. Targeted confirmation (5 fresh lenses, confirm-or-reject only): **5× PASS** (`docs/reviews/sprint-0001-final-confirmation.md`).

**Zero unresolved freeze-blocking findings.**

## Human-approved Wave-1 amendment

Recorded in full in `WAVE1_FREEZE.md`: prior frozen commit `0838854`; amendment commit `8095d7b` (database-contract.md only); reasons: (1) request-hash scope corrected to cover tenant-scoped path identifiers (incl. contactId) plus the normalized body, excluding server-generated fields — aligning the frozen source with Node A's correct rule; (2) post-increment `attempt_count` added to the outbox-claim and consumer-attempt-start RETURNING lists — the values Node E's ceilings are keyed on; policy ownership unchanged.

## Ratification — lease internals withheld from the tenant surface

- `seq`, `claim_id`, `claimed_by`, and `lease_expires_at` are internal coordination metadata.
- They are not part of the tenant-facing processing-status contract.
- Their omission is intentional and preserves engine neutrality (a future WarpStream/Mojo publisher need not reproduce the current worker topology).
- D §7.1's per-state field list is the database-level derivation/operator surface; the tenant surface is A §9's allowlist, which additionally exposes `attempt_count` and sanitized `last_error` — the fields with genuine diagnostic value. Operators retain database-level access via P §6.6's carve-out.

## Independent validation results (pre-freeze, human-authorized temporary tooling; nothing committed to the repo)

**OpenAPI** — `@apidevtools/swagger-parser` validate: **PASS, zero errors** (OpenAPI 3.0.3, 11 paths, all $refs resolved). Fixture demonstrations (Ajv, with the standard OpenAPI-3.0 nullable→type-union conversion): real `CompanyDetail` 200 validates; real `ContactDetail` 200 validates; `ProcessingStatus` with `consumer: null` and `failure: null` validates; failed-state `ProcessingStatus` with `failure.secondary: null` validates; undeclared properties rejected on response schemas; `LogInteractionRequest` accepts a valid body and rejects `occurred_at` (closed schema). Independently reproduced by the QA and data-correctness confirmation reviewers.

**JSON Schema** — Ajv 2020-12, `strict: true`, ajv-formats in assertion mode: both `event-envelope.v1.schema.json` and `interaction-logged.v1.schema.json` **compile with zero errors**; valid fixtures pass; malformed fixtures fail (`event_id`/`tenant_id`/`actor_id` = "banana", `occurred_at`/`next_action_date` malformed, out-of-enum outcome, extra properties); `causation_id` present-but-null accepted. Duplicate-key-aware parsing (custom strict parser): no duplicate keys at any depth; envelope `properties` and `required` are exactly the frozen twelve names, each once; `additionalProperties: false` intact.

**Sprint-0002 CI gate (mandatory):** implementation of any endpoint may not begin until `docs/specs/api.openapi.yaml` passes an independent, standards-aware OpenAPI 3.0.3 validator (Redocly CLI, @apidevtools/swagger-parser validate, or equivalent) in a mode that fully resolves $refs and validates schema composability, with zero errors, run in CI — re-demonstrating the two previously fixed composition defect classes (allOf-over-closed-base; nullable+allOf) stay fixed — and both event schemas must compile under a JSON Schema draft 2020-12 validator in strict mode with format assertion enabled, with the negative fixtures failing. Any change a validator forces is a contract fix requiring re-review before the corresponding endpoint is built.

## Sprint-0002 obligations carried forward

1. **withTenantWrite enforcement gate** (WAVE1_FREEZE Obligation 1): every tenant-owned mutation through the shared helper; raw tenant-write transaction access not exported to endpoint modules; automated tests prove every mutation path performs the in-transaction `FOR SHARE` membership recheck.
2. **last_error hygiene** (Obligation 2, discharged at contract level in E §9): the hygiene test gate is mandatory before any non-local deployment.
3. **AuditEvent.details schema-closure test** (security confirmation observation): the one open-schema response object; content contractually confined to `task_id`/`outcome` — add a closure test at implementation.
4. **Pre-external-exposure requirements** recorded in the contracts: rate limiting (P-AUTH-8), partition/tenant fairness or bounded blocking (E §8.2.2), real credentials/TLS/SASL (I §1), `/readyz` body review (I §7).
5. **Deliberate tight coupling recorded:** the payload schema pins P's outcome vocabulary (vocabulary change ⇒ payload schema major bump, deploy-consumers-first); revisit only when a consumer first deploys independently of the API.

## Change control after this freeze

No file under `docs/specs/` may change except under a new human-approved bounded loop. Implementation (Sprint 0002) begins only after human approval at this gate, and per CLAUDE.md never merges or pushes to `main` without passing the full quality gates and independent reviews.
