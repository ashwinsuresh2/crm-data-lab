# Sprint 0001 — Final Five-Lens Review: Architecture Lens

- **Reviewed commit:** `c8b7f11` on `sprint-0001-contracts` (2026-08-20); Wave-1 verified byte-identical since `0838854`
- **Reviewer:** fresh architecture-reviewer agent instance (read-only), against CLAUDE.md and PROJECT_CHARTER.md

## Boundary verification (all PASS)

Replacement boundaries (domain-oriented topic naming with mechanism names forbidden; envelope carries no broker fields; retry/dead-letter implementable on any Kafka-compatible engine; API exposes no broker/storage internals; U routes everything through A). Browser→API only (every U dependency a marked Node A seam). Authoritative-vs-derived (7-day retention safe because the outbox is the record; inspection state derived strictly per D §7.1). Atomicity/idempotency (A §7.8 restates D §2 exactly; A's key-binding rule matches D §3). Contract formats/versioning (OpenAPI 3.0.3 + JSON Schema 2020-12; /v1, .v1, schema_version mutually coherent). Fleet/cost (no new services; **the no-DLQ decision — dead letter as a terminal failed state in PostgreSQL — is the best tiny-fleet call in the set**; $0 floor). Topology coherence (topic init idempotent per I §7; crm.events.v1/crm-worker ownership E's with I's names illustrative; consumer_name = group.id unification). event_id = outbox_event.id pinned end to end. Dead-letter-as-failed maps onto the existing four states — no phantom fifth state.

## Findings

**F1 — MAJOR — WAVE2-FIXABLE — Kafka offset can reach a tenant inside last_error** (E §9 safe-scalar list × A §9 surface): the same leak class D §7.1 bans for seq, reintroduced via string composition; U renders the summary as opaque text so its field ban doesn't save it. Owning: E (primary), A (defense-in-depth). *(Resolved `66f597d`/`a057a15`; confirmed.)*

**F2 — JUDGMENT CALL (assessed, no edit) — A withholding claimed_by/lease_expires_at is architecturally right.** (1) P outranks D on the tenant-visible surface and declares the lease internal; (2) engine-neutrality: claimed_by is publisher-infrastructure identity — exposing it bakes worker topology into the product contract; (3) A's selective adoption (it does expose attempt_count/last_error from the same D §7.1 row) proves the coherent reading of that column as the internal derivation/operator surface. No Wave-1 edit needed; ratify in CONTRACT_FREEZE/ADR text. *(Human ruling: ratified.)*

**F3 — ASSESSMENT — payload outcome-enum pinning is the right discipline** for a no-registry, co-deployed, single-consumer system: silent unknown-token flow into future derived stores is precisely the authoritative-vs-derived corruption this project guards against; bump cost near zero while both ends co-deploy. Record as deliberate tight coupling; revisit only when a consumer first deploys independently.

**F4 — MINOR — WAVE2-FIXABLE — Task.status enum included unreachable "done".** *(Resolved in `a057a15`.)*

**F5 (addendum) — MINOR — WAVE2-FIXABLE — "byte-for-byte" replay promise unfulfillable** (jsonb discards bytes at commit; even first publication is a re-serialization) and a replacement-boundary violation in miniature (promotes serializer key order into the durable contract; breaks engine swap). Frozen I §6 already promises only value identity, so E's stronger wording was the deviation — no Wave-1 touch. §2.2's "reconstruct the topic" also misreadable. Recommended logical-identity rewording + new-records-at-new-offsets distinction. *(Resolved in `66f597d`; confirmed.)*

## Addendum — Independent OpenAPI validation status

**Conclusion (B) at review time** — verified directly: no Redocly/Spectral/swagger-cli/openapi-generator/vacuum on PATH, empty global npm tree, no Python validator, no repo node_modules; nothing installed. Node A's round-trip + structural checks are self-referential (they would not catch nullable-under-allOf misuse). Recommended CONTRACT_FREEZE gate: no endpoint implementation until the YAML passes an independent standards-aware validator with zero errors in CI, validator-forced changes re-reviewed. *(Subsequently satisfied pre-freeze via human-authorized temporary tooling; CI re-run remains a Sprint-0002 gate.)*

## Verdict

PASS with one bounded pre-freeze fix-batch (F1 + F5, both Wave-2-only edits to event-contract.md — since applied and confirmed); ratify F2's interpretation and record the A2(B) validation gate; the contract set is architecturally coherent, engine-swappable, and tiny-fleet-faithful.
