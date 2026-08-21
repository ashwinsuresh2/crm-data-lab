# Sprint 0001 — Wave-1 Barrier Review: Security Lens

- **Reviewed commit:** `1c4dd59` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** security-reviewer agent (read-only)
- **Documents:** docs/specs/product-behavior.md, domain-model.md, database-contract.md, local-topology.md

---

## Question C — Membership revocation race

### Current contract state (the gap is real and already half-admitted)

- database-contract.md §2: "Authorization (active membership in `$tenant` ...) is checked **before the transaction**; the composite FKs ... re-enforce tenant consistency inside it."
- domain-model.md §2.3 tradeoff: "the composite actor FK proves the actor *was granted* membership ... it does not prove the membership was `active` at write time (FKs cannot see `status`)."
- P-AUTH-3b's test verifies per-request checking but cannot detect a revoke landing **between** the pipeline check and the transaction commit of a single in-flight request. §2.3's "Revocation immediately removes access" is therefore not literally guaranteed: a request can commit an Interaction, Task, Audit event, and Outbox event with an actor whose membership was already revoked at commit time.

### Option (a): in-transaction recheck with a row lock

As step (0a) of the §2 transaction:

```sql
SELECT 1 FROM membership
 WHERE tenant_id = $tenant AND user_id = $actor AND status = 'active'
 FOR SHARE;
-- 0 rows → abort transaction, return the pipeline's unauthorized/not-found response
```

Correctness under READ COMMITTED:
- Revoke committed first → recheck returns 0 rows → reject.
- Revoke in flight (uncommitted): the plain UPDATE holds `FOR NO KEY UPDATE`, which conflicts with `FOR SHARE`; the recheck blocks, then re-evaluates against the updated row (EvalPlanQual) → 0 rows → reject.
- Write takes the share lock first → the concurrent revoke blocks until the write commits — revocation strictly serializes after the write. Every committed write provably happened while the membership was active in commit order.
- **`FOR KEY SHARE` is NOT sufficient.** A status flip is a non-key update (`FOR NO KEY UPDATE`), which does not conflict with `FOR KEY SHARE`; the race would remain. The contract must say `FOR SHARE` explicitly.

Cost: one index lookup on the existing `UNIQUE (tenant_id, user_id)` per write transaction — negligible. Revokes briefly queue behind in-flight writes — semantically desirable. Deadlock risk minimal if the recheck is always statement zero.

Failure mode: opt-in per mutation path — a future endpoint could forget it. Mitigation: implement once in a shared `withTenantWrite(tenant, actor, fn)` transaction helper; forbid raw transaction access by convention plus a test asserting every mutation path uses the helper.

Test observability: excellent — deterministic integration tests with an injected pause; plain SQL, visible in query logs, testable against real Postgres in CI.

### Option (b): PostgreSQL RLS keyed on `SET LOCAL app.tenant_id / app.user_id`

- **Does not solve Question C by itself.** An RLS policy with an `EXISTS (... status='active')` subquery takes no lock on the membership row; under READ COMMITTED it is evaluated per statement snapshot. A concurrent revoke neither blocks nor is blocked — the commit-time race persists. The locking recheck of (a) would still be needed.
- Substantial Sprint-0002 cost and sharp failure modes: table-owner/`BYPASSRLS` silently disables policies unless migration and app roles are split and `FORCE ROW LEVEL SECURITY` is used (a misconfiguration where all tests stay green); connection-pool leakage if anyone uses `SET` instead of `SET LOCAL` (a cross-tenant context-bleed bug class worse than the one being fixed); awkward error normalization into the 5.4 uniform not-found body.
- Test observability poor: enforcement is implicit, and the main risk (owner bypass) is invisible to functional tests.
- database-contract.md §1 item 8 already frames RLS as a future hardening seam.

### Recommended decision (single, explicit)

**Adopt (a) for Sprint 0002:** mandatory in-transaction `SELECT ... FROM membership WHERE tenant_id=$1 AND user_id=$2 AND status='active' FOR SHARE` (explicitly not `FOR KEY SHARE`) as the first statement of every tenant-owned write transaction, implemented in one shared transaction helper that all mutation paths must use; the recheck may additionally join `tenant.status='active'` to close the same race for tenant suspension. Keep RLS as the Sprint-0003+ defense-in-depth layer, gated on role separation and `FORCE ROW LEVEL SECURITY`.

Not flagged as HUMAN DECISION REQUIRED: for the specific property demanded, option (b) without locking does not satisfy it — the options are not equally defensible. *(Human ruling 2026-08-20: ratified.)*

---

## Findings

**F1 — Membership-active TOCTOU window in the write transaction.**
Severity: **major**. Contract: database-contract.md §2 (consequences bullet 2); domain-model.md §2.3; product-behavior.md P-AUTH-3b. Concrete failure: at 10:00:00.000 the pipeline verifies user U active in tenant T; at 10:00:00.005 an admin transaction commits `status='revoked'`; at 10:00:00.010 U's write transaction commits an interaction, task, audit row, and outbox event — authored by a revoked member, contradicting "revocation immediately removes access." Owning node: **D** (with a P-AUTH-3b test-note addition by P). Resolution: the Question C decision; amend §2 step (0) and §2.3; extend P-AUTH-3b to the concurrent case.

**F2 — Outbox processing-state inspection surface has no auth/tenant-scoping requirement.**
Severity: **major**. Contract: product-behavior.md §6.4 ("operator-facing view or query surface — presentation owned by Node A"); database-contract.md §7. Concrete failure: Node A legitimately satisfies §6.4 with an unauthenticated `/admin/outbox` endpoint or cross-tenant listing; outbox `payload` is the full business envelope, so tenant A's tester reads tenant B's interaction events — a cross-tenant leak through the only surface the contracts exempt from the auth pipeline by omission. Owning node: **P** (constraint), then A. Resolution: one sentence in §6.4 — the inspection surface passes the same P-AUTH pipeline, scoped to the active tenant, 5.4 not-found semantics for other tenants' events.

**F3 — `consumer_receipt.tenant_id` is unvalidated against the event it receipts.**
Severity: minor. Contract: database-contract.md §4, §6, §7. Concrete failure: a consumer bug writes a receipt for tenant A's event with tenant_id = B (plain FK accepts any tenant); tenant A's event derives "published, unprocessed" forever while tenant B shows a phantom processed event — corrupting per-tenant inspection with no constraint violation. Owning node: **D**. Resolution: `FOREIGN KEY (tenant_id, event_id) REFERENCES outbox_event (tenant_id, id)`, matching the composite-FK convention.

**F4 — Dev-token stub guard is single-factor on `APP_ENV`; token format/entropy/seed storage unspecified.**
Severity: minor. Contract: local-topology.md §9; product-behavior.md §1, P-AUTH-5. Concrete failure: (i) config drift sets `APP_ENV=local` on a future non-local deployment — the stub ships; (ii) tokens seeded as guessable literals committed in fixtures — combined with F5, anyone reaching the port authenticates as any tenant. `AUTH_MODE` unset/unknown behavior unspecified. Owning node: **I** (guard), **P** (token definition). Resolution: guard additionally refuses dev-token mode when `NODE_ENV=production` or bind address is not 127.0.0.1; tokens are seeded random values (≥128-bit) generated at seed time, never committed; unknown `AUTH_MODE` fails startup.

**F5 — Loopback-only binding asserted but not test-enforced; Node/Next defaults are all-interfaces.**
Severity: minor. Contract: local-topology.md §4. Concrete failure: Sprint 0002 starts `next dev`/the API without an explicit host option; both listen on all interfaces; on shared Wi-Fi a LAN attacker hits :3001 with a guessable dev token (F4) and reads/writes all tenants. Owning node: **I**. Resolution: startup assertion (fail fast if resolved listen host is not 127.0.0.1 while `AUTH_MODE=dev-token`) plus an automated loopback check.

**F6 — Membership grant/revoke and consumer side effects escape the audit trail.**
Severity: minor. Contract: domain-model.md §2.3, §2.8 (no `membership.*` verbs); database-contract.md §6. Concrete failure: P-AUTH-3b makes revocation a live behavior-bearing mutation, yet it leaves no audit row — access changes are the one class the audit view cannot answer "who did what, when" for. Owning node: **D** (P for the audit-view expectation). Resolution: any future membership mutation path emits `membership.granted`/`membership.revoked` audit events in the same transaction; fixture revocation exempt but must use that path once an endpoint exists; consumer records audited-or-explicitly-exempt.

**F7 — No requirement to log or rate-limit authentication/authorization denials.**
Severity: minor. Contract: product-behavior.md §2, §5.4, §5.6; no rate-limit statement anywhere. Concrete failure: dev-token or cross-tenant ID enumeration at unbounded rate; nothing obliges recording or throttling — the abuse is invisible. Acceptable for a loopback-only dev slice, but should be a recorded decision, not an omission. Owning node: **P** (behavioral requirement), **I** (where logs live). Resolution: authn/authz denials server-logged (actor claim, tenant, route, timestamp — no token values); rate limiting an explicit pre-exposure TODO.

**F8 — Local infra trust boundary is the whole machine (known Postgres creds, unauthenticated Kafka).**
Severity: minor (informational). Contract: local-topology.md §9, §4. Concrete failure: any process on the developer machine connects to 127.0.0.1:5432 with published credentials and mutates authoritative data or forges outbox events, bypassing API, audit, and tenant isolation. Owning node: **I**. Resolution: no change for the slice; state the trust boundary explicitly so the assumption is invalidated deliberately before any non-loopback deployment.

**Areas checked, no findings:** idempotency-key scope `(tenant_id, actor_user_id, operation, key)` correctly closed (no cross-tenant/cross-actor replay; replay responses only to the original tenant+actor; hash-mismatch leaks key existence only to the same actor); cross-tenant vs not-found indistinguishability consistent across reads, writes, and referential lookups except F2; migration conventions contain no destructive hazard; `down -v` properly warned and project-scoped; audit atomicity and five-dimension coverage complete for the three in-slice mutations; no webhooks in the slice.

## Verdict

**Conditionally ready:** freeze after amending database-contract.md §2 / domain-model.md §2.3 with the F1 `FOR SHARE` recheck and adding the one-sentence auth requirement to product-behavior.md §6.4 (F2); F3–F8 carried as recorded Sprint-0002 obligations.
