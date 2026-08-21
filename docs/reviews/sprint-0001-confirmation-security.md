# Sprint 0001 — Confirmation Pass: Security Lens

- **Reviewed commit:** `87efe3f` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** fresh security-reviewer agent instance (read-only; independent of prior passes)
- **Prior review:** docs/reviews/sprint-0001-barrier-security.md

## Per-item verdicts

1. **F1 membership TOCTOU — PASS.** database-contract §2: `withTenantWrite` mandated for every tenant-owned write; statement zero `SELECT 1 FROM membership m JOIN tenant t ... WHERE ... m.status='active' AND t.status='active' FOR SHARE OF m, t;` with "no row returned → ROLLBACK immediately; no writes occur" — a strict superset of the ruling (also closes tenant suspension). `FOR KEY SHARE` explicitly rejected with the correct non-key-update rationale, restated in domain-model §2.3. RLS pinned as later defense-in-depth in both files. P-AUTH-3b covers the concurrent-revocation observable behavior with mechanism ownership left to D. Locking semantics verified correct under READ COMMITTED (FOR NO KEY UPDATE conflicts with FOR SHARE; serialization holds in both orders).
2. **F2 inspection-surface auth — PASS.** product-behavior §6.4 names all five demanded properties verbatim, with a concrete cross-tenant test; wired into AC-9.
3. **F3 receipt tenant validation — PASS.** `FOREIGN KEY (tenant_id, event_id) REFERENCES outbox_event (tenant_id, id)` with explanatory comment; target unique constraint exists.
4. **F4 dev-token guard — PASS.** local-topology §9: four-condition multi-factor fail-closed guard (unknown AUTH_MODE fails startup; APP_ENV; NODE_ENV=production; non-loopback bind), no override flag; tokens seeded random ≥128-bit, stored only in the local DB, never committed.
5. **F5 loopback enforcement — PASS.** §7 fail-fast startup assertion + automated loopback-socket test; repeated in the §10 self-check.
6. **F6 membership/consumer auditability — PASS.** domain-model §2.3 grant/revoke audit rule (same transaction; fixtures exempt until an endpoint exists); §2.8 audited-or-explicitly-exempt bullet exempting worker outbox transitions and receipts with rationale; action vocabulary lists both membership verbs.
7. **F7 denial logging + rate limiting — PASS** (one consistency residue, R3b). P-AUTH-8 covers every denial class with fields specified, tokens never logged, a test, and rate limiting as an explicit pre-exposure future requirement.
8. **F8 trust boundary — PASS.** local-topology §1: boundary is the developer machine; loopback-only rationale; must be deliberately invalidated (real credentials, TLS, SASL/SCRAM) before any non-loopback deployment.
9. **Regression sweep — PASS, no tenant-isolation or leak regression.** Receipt rows structurally pinned to their event's tenant (composite FK); the §7.2 join carries tenant predicates on every hop and the surface is bound to the full auth pipeline, so failure_stage/last_error/processed_at are reachable only within the row's own tenant; claim_id never exposed on the §7.1 surface; claimed_by observability-only; all new outbox/linkage columns live on tenant-owned rows with tenant-leading indexes except the two deliberate worker-path exceptions.

## Findings (minor residue — Sprint-0002 obligations, none blocking freeze)

**R1 (minor) — `seq` exposure not explicitly forbidden.** database-contract §7.1 / product-behavior §6.4. `outbox_event.seq` is a global monotonic counter across tenants; if Node A surfaced it, a tenant could infer other tenants' write volume from gaps. The exposed-field lists exclude it today, but nothing forbids it. Owning node: D (or A). Resolution: add "seq is internal processing order and MUST NOT be exposed on any tenant-facing surface."

**R2 (minor) — `last_error` content hygiene unspecified.** database-contract §5/§6/§7.1. Tenant-scoped, but nothing constrains content; broker/driver error strings can embed infrastructure detail or, under future authenticated setups, credential material, and §7.1 exposes them to tenant members. Owning node: E/D. Resolution: one sentence — last_error is a truncated, sanitized message (never tokens, credentials, connection strings) before any non-local deployment.

**R3 (minor) — helper-coverage test and denial-log field drift.** (a) The F1 mitigation included a test asserting every mutation path uses `withTenantWrite`; the helper is mandated but no spec records the enforcement test — carry into Sprint-0002 quality gates (owning node: D/QA). (b) local-topology §7 lists denial-log fields as "actor, tenant, action, record, and time" vs P-AUTH-8's authoritative "actor claim, tenant, route, timestamp" — Node I should align to avoid an implementation omitting `route`.

## Verdict

**PASS — security freeze approved:** all eight prior findings resolved as ruled; the remediated receipt/claim/derivation texts introduce no tenant-isolation or information-leak regression; R1–R3 are recorded Sprint-0002 obligations, not freeze blockers.
