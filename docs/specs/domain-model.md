# Domain Model — First Vertical Slice (Sprint 0001, Node D)

Status: contract document for Sprint 0001, remediation pass 2 (barrier rulings
ratified by the human). Documentation only; no runnable code.
Companion document: `docs/specs/database-contract.md` (PostgreSQL specifics, transaction
boundary, idempotency storage, outbox publication, consumer receipts, illustrative DDL).

This document defines the nine domain objects of the first vertical slice, their fields,
relationships, invariants, and tenant-scoping rules. Field names given here are the
canonical logical names; the database contract maps them 1:1 to columns.

---

## 1. Scoping rules: global vs tenant-owned

Two objects are **global** (they exist above any single tenant):

| Object | Why global |
|---|---|
| Tenant | The tenant registry itself cannot be owned by a tenant. |
| User | One human identity may belong to multiple tenants; identity is resolved before tenancy. |

Seven objects are **tenant-owned**. Every tenant-owned row carries a non-null
`tenant_id` foreign key to Tenant, from day one, with no exceptions:

- Membership
- Company
- Contact
- Interaction
- Task
- Audit event
- Outbox event

(Two request/event-processing storage rows defined in the database contract — the
idempotency-key row and the consumer-processing receipt — also carry `tenant_id`;
they are processing storage, not additional domain objects. The consumer receipt's
`(tenant_id, event_id)` is a composite FK to the Outbox event, so even processing
storage cannot hold a tenant-inconsistent reference.)

**Isolation rule.** No query, mutation, or event emission may address a tenant-owned
row without an explicit `tenant_id` predicate. Cross-tenant references are structurally
impossible: all foreign keys between tenant-owned rows are composite
`(tenant_id, <id>)` keys (see database contract, "Key and index conventions"), so a row
in tenant A can never reference a row in tenant B even if application code is buggy.

**Tenant-valid actor rule.** Wherever a tenant-owned row references a user
(`created_by`, `assigned_to`, `actor_user_id`), the reference is a composite foreign
key `(tenant_id, user_id)` targeting Membership — not a plain FK to the global User
table. A tenant-owned row therefore cannot name a user who was never a member of that
tenant. Active-ness of that membership at write time is enforced **inside** every
tenant-owned write transaction by the shared `withTenantWrite` recheck (database
contract §2, statement zero), which also closes the revocation/suspension race.

**Identifier rule.** All primary identifiers are UUIDs generated server-side. Clients
never mint IDs for authoritative records.

**Timestamp rule.** All timestamps are UTC `timestamptz`. `created_at` is set by the
database at insert. In this slice, `Interaction.occurred_at` is also assigned
server-side at write time (clients do not supply it). Calendar-date fields
(`Task.due_on`, the next-action date) use SQL `date` and are interpreted against the
tenant's `operating_timezone`.

---

## 2. Objects

### 2.1 Tenant (global)

The unit of data isolation and, later, of external customer onboarding.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| name | text | Display name; non-empty. |
| operating_timezone | text | Required IANA timezone identifier (e.g. `America/New_York`). Defines how date-typed fields such as `Task.due_on` are interpreted (e.g. what "due today" and end-of-day mean). Validated at the API layer against the IANA set. |
| status | text | `active` \| `suspended`. Slice only uses `active`. |
| created_at | timestamptz | |

Invariants:
- A suspended tenant's members fail authorization for all reads and writes. This is
  slice behavior enforced twice: at the resolve-membership pipeline step, and again
  inside every tenant-owned write transaction by the `withTenantWrite` recheck
  (database contract §2), which locks the tenant row `FOR SHARE` so an in-flight
  suspension cannot race a write. Node P owns the tester procedures for the
  suspended-tenant rule (human ruling); this document owns the enforcement mechanism.

### 2.2 User (global)

A human identity. Authentication for the slice is a **dev-token stub**: a header-based
dev token resolves directly to a seeded User. The authenticate → resolve-membership →
authorize pipeline is real; only the credential verification step is stubbed.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| email | text | Unique, case-insensitive. Identity anchor. |
| display_name | text | Non-empty. |
| status | text | `active` \| `deactivated`. |
| created_at | timestamptz | |

Invariants:
- Email is globally unique (identity is global; tenancy is granted via Membership).
- **Credential seam:** no password/credential columns exist in the slice. When real
  auth arrives, credentials attach as a separate `user_credential` table keyed by
  `user_id` (or an external IdP subject mapping). Nothing else in the model changes:
  authentication still terminates in a resolved `user_id`, and everything downstream
  (membership resolution, authorization, auditing) is already keyed on `user_id`.
- A `deactivated` user fails authentication regardless of dev token. This is slice
  behavior; Node P owns the tester procedures for the deactivated-user rule (human
  ruling); this document owns the enforcement mechanism.

### 2.3 Membership (tenant-owned)

The join between User and Tenant; the sole source of tenant access, the anchor for
authorization, and the FK target that makes every actor reference on tenant-owned rows
provably tenant-valid.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| user_id | uuid | FK → User. |
| role | text | `owner` \| `member`. Slice treats both as full read/write within the tenant; the field exists so authorization is enforceable and extensible. |
| status | text | `active` \| `revoked`. |
| created_at | timestamptz | |

Invariants:
- At most one Membership per `(tenant_id, user_id)`; that unique pair is the target of
  every composite actor FK in the model.
- Authorization rule for the slice: a request may touch a tenant-owned row **iff** the
  authenticated user holds an `active` Membership in that row's `tenant_id`. There is
  no cross-tenant read or write under any role.
- Membership rows are **never deleted**, only status-revoked. This keeps historical
  actor references (audit rows, `created_by`, `assigned_to`) structurally valid
  forever. Revocation immediately removes access; it does not touch data.
- **Revocation race, closed (ratified ruling):** the composite actor FK proves the
  actor *was granted* membership; active-ness **at write time** is enforced inside
  the write transaction itself. Every tenant-owned write goes through one shared
  `withTenantWrite` helper whose statement zero is
  `SELECT 1 FROM membership WHERE tenant_id = $tenant_id AND user_id = $user_id AND
  status = 'active' FOR SHARE` — no returned row aborts the transaction with no
  writes. `FOR SHARE` conflicts with the revoking `UPDATE` of `status` (a non-key
  update), so revocation and an in-flight write serialize; `FOR KEY SHARE` is
  explicitly **not** acceptable because a status flip is a non-key update and would
  not conflict. The same recheck verifies `tenant.status = 'active'`, closing the
  suspension race identically. RLS remains later defense-in-depth, not the
  Sprint-0002 solution. Full mechanism: database contract §2.
- **Membership auditability:** any future membership grant/revoke mutation path
  (API endpoint) must emit `membership.granted` / `membership.revoked` audit events
  in the same transaction as the status change. Fixture/seed-based membership setup
  and revocation in this slice is exempt, but must migrate to that audited path the
  moment an endpoint exists.

### 2.4 Company (tenant-owned)

An organization the salesperson sells to.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| name | text | Non-empty. **Not unique within a tenant** — duplicate company names are allowed (real portfolios contain distinct companies with identical names; disambiguation is a UX concern, not a constraint). |
| created_by | uuid | Composite FK `(tenant_id, created_by)` → Membership `(tenant_id, user_id)`. |
| created_at | timestamptz | |
| updated_at | timestamptz | Maintained on every mutation. |

### 2.5 Contact (tenant-owned)

A person, attached to a Company.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| company_id | uuid | **Required (NOT NULL)** in Sprint 0001. Composite FK → Company `(tenant_id, company_id)`. Unaffiliated contacts are out of scope for the slice; relaxing to nullable later is a forward-only migration. |
| full_name | text | Non-empty. |
| email | text, nullable | No uniqueness constraint in the slice (real-world duplicates exist; dedup is a later feature). |
| phone | text, nullable | |
| last_contacted_at | timestamptz, nullable | **Derived-but-authoritative** field: updated inside the log-interaction transaction. Null until first interaction. |
| created_by | uuid | Composite FK `(tenant_id, created_by)` → Membership `(tenant_id, user_id)`. |
| created_at | timestamptz | |
| updated_at | timestamptz | |

Invariants:
- The Contact's Company belongs to the same tenant (enforced by the composite FK, not
  just application code).
- `last_contacted_at` only moves forward: it is set to
  `greatest(current value, interaction.occurred_at)` inside the log-interaction
  transaction, so replays never rewind it.

### 2.6 Interaction (tenant-owned)

An immutable record of a touch with a Contact. The slice supports logging a call with
an outcome and a mandatory next-action task.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| contact_id | uuid | Composite FK → Contact `(tenant_id, contact_id)`. |
| kind | text | `call` in the slice; field exists so email/meeting capture lands without schema redesign. |
| outcome | text | Non-empty. Values are stable **tokens** from the product-owned closed vocabulary in Node P's contract (e.g. token `not_interested` is stable even though its visible label is now "Not interested now" — labels are Node P's, tokens do not change). Validation model: database contract §1 item 5. |
| notes | text, nullable | Free text. |
| occurred_at | timestamptz | **Assigned server-side at write time** (transaction time). Not client-supplied in this slice; backdating is future work and will itself be audited. |
| created_by | uuid | Composite FK `(tenant_id, created_by)` → Membership `(tenant_id, user_id)`; the actor who logged it. |
| created_at | timestamptz | When it was recorded (equals `occurred_at` in this slice by construction; kept as separate fields because they diverge once backdating exists). |

Invariants:
- Interactions are **append-only**: no update or delete in the slice. Corrections are
  future work and will themselves be audited.
- **Every successful Interaction creates exactly one linked open Task** (the
  next-action task). It is not optional. Every Interaction insert is accompanied, in
  the same transaction, by the contact timestamp update, exactly one next-action
  Task, exactly one Audit event, and exactly one Outbox event (see database
  contract §2).
- Each Interaction's Outbox event is directly queryable by ordinary SQL join via the
  outbox linkage columns (`aggregate_type = 'interaction'`,
  `aggregate_id = interaction.id`); see §2.9 and database contract §7.

### 2.7 Task (tenant-owned)

An explicit next action. In the slice, every task is the mandatory next-action task of
exactly one Interaction; the model does not preclude standalone tasks later.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| contact_id | uuid | Composite FK → Contact `(tenant_id, contact_id)`. |
| interaction_id | uuid | Composite FK → Interaction `(tenant_id, interaction_id)`. The provenance link that makes "why does this task exist" answerable. Nullable in schema only to leave room for future standalone tasks; in Sprint 0001 every task has it set. |
| title | text | Non-empty. **Node P owns deterministic task titles per outcome** — the title is generated from the interaction's outcome token per Node P's contract, not free-typed by the client in this flow. |
| due_on | date | The selected next-action **date** (SQL `date`, not a timestamp). Interpreted against the tenant's `operating_timezone` (e.g. "due today", overdue-at-end-of-day). Client selects the date; server stores it as-is. |
| status | text | `open` \| `done` — exactly these two states in this slice. Created as `open`. |
| assigned_to | uuid | Composite FK `(tenant_id, assigned_to)` → Membership `(tenant_id, user_id)`. Slice assigns to the actor who logged the interaction. |
| created_by | uuid | Composite FK `(tenant_id, created_by)` → Membership `(tenant_id, user_id)`. |
| created_at | timestamptz | |
| updated_at | timestamptz | |
| completed_at | timestamptz, nullable | Set when status becomes `done`. |

Invariants:
- **Exactly-one-task guarantee:** the log-interaction transaction creates exactly one
  Task per Interaction (existence), and the partial unique index on
  `(tenant_id, interaction_id)` enforces at-most-one task **per interaction**
  (uniqueness). Note the index's scope precisely: it guarantees only the
  task-per-interaction half. The "one interaction" half of the duplicate-request
  acceptance criterion rests **solely** on the idempotency-key primary key
  (database contract §3). The Kafka consumer never creates tasks at all — see §2.9
  and database contract §6 — so duplicate event delivery is not a task-duplication
  vector.
- `completed_at` is non-null iff `status = 'done'`.

### 2.8 Audit event (tenant-owned)

The append-only answer to "who did what, to which record, in which tenant, when."

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| actor_user_id | uuid | Composite FK `(tenant_id, actor_user_id)` → Membership `(tenant_id, user_id)`. The authenticated actor, provably a member of the tenant. |
| action | text | Verb-object string, e.g. `interaction.logged`, `company.created`, `contact.created`, `task.completed`, and (future endpoints) `membership.granted`, `membership.revoked`. |
| record_type | text | Logical object name, e.g. `interaction`. |
| record_id | uuid | ID of the primary affected record. |
| occurred_at | timestamptz | Transaction time of the action. |
| details | jsonb | Small structured context (e.g. related task ID, outcome token). Never used as the system of record for the objects themselves. |

Invariants:
- Append-only: no updates, no deletes, ever. (The database contract adds a
  belt-and-braces enforcement note.)
- Written **in the same transaction** as the change it describes — an audited change
  and its audit row are atomic; neither can exist without the other.
- Captures all five required dimensions of the acceptance criteria: actor
  (`actor_user_id`), tenant (`tenant_id`), action (`action`), record
  (`record_type` + `record_id`), time (`occurred_at`).
- Because Membership rows are never deleted (§2.3), audit rows remain structurally
  valid even after the actor's membership is revoked.
- **Audited-or-explicitly-exempt:** all human-actor mutations are audited in-transaction.
  Worker-produced processing records — outbox publication state transitions and
  consumer receipts — are **explicitly exempt** from `audit_event`: they have no
  human actor (the actor FK targets Membership), and they are themselves the
  inspection record for the asynchronous path (database contract §7). Any future
  membership grant/revoke endpoint is audited per §2.3.

### 2.9 Outbox event (tenant-owned)

The durable staging row for at-least-once event publication. The **event envelope
content** (field names inside the JSON payload, event types, topic mapping) is Node E's
contract; this model defines the **row shape** that stores and tracks it, plus the
linkage columns that make the event stream queryable from the domain.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key; the stable event identity. **Invariant (Node E seam): the envelope's `event_id` MUST equal `outbox_event.id`.** This is what makes consumer receipts and end-to-end joins line up. |
| seq | bigint | Monotonic insertion sequence (database identity column); the publisher's processing-order key. |
| tenant_id | uuid | FK → Tenant. Present on the row even though the envelope also carries tenant scope, so outbox rows are queryable and isolatable like every other tenant-owned row. |
| event_type | text | e.g. `interaction.logged`. Mirrors the envelope's type for SQL-level querying. |
| aggregate_type | text | Logical domain object the event is about, e.g. `interaction`. |
| aggregate_id | uuid | ID of that domain row, e.g. `interaction.id`. With `aggregate_type` + `tenant_id`, gives a direct SQL join from domain row → outbox event. |
| aggregate_version | bigint | Version of the aggregate at emission; `1` for append-only interactions in this slice. |
| payload | jsonb | The complete JSON event envelope, opaque to this layer, validated against Node E's JSON Schema at write time by the producing code path. |
| status | text | `pending` \| `published` \| `failed`. Created as `pending`. |
| claim_id | uuid, nullable | **Ownership guard** for the current publication claim; regenerated fresh on every claim attempt. All lease-holder updates are conditioned on it (database contract §5). |
| claimed_by | text, nullable | Identity of the publisher worker holding the current claim lease. **Observability only — never the ownership guard.** |
| lease_expires_at | timestamptz, nullable | When the current claim lease lapses; an expired lease makes the row claimable again. |
| attempt_count | integer | Publication attempts so far; starts at 0. |
| last_error | text, nullable | Most recent publication error, for inspection. |
| created_at | timestamptz | |
| published_at | timestamptz, nullable | Set when status becomes `published`. |

Invariants:
- Written **in the same transaction** as the business change it announces; a committed
  change always has its event staged, and a rolled-back change never leaks an event.
- **No database transaction or row lock is ever held across the Kafka network call.**
  Publication uses a short claim-lease transaction, an out-of-transaction Kafka
  publish, and a short acknowledge transaction, with `claim_id` as the ownership
  guard on every lease-holder update; a worker whose guard no longer matches has
  lost the lease and stops modifying the row (database contract §5).
- A `pending` row is **not yet confirmed published; it may already be in the event
  stream** (at-least-once): a crash after broker acknowledgement but before the
  acknowledge transaction leaves the row `pending` until re-claim and re-publish.
  Consumers are idempotent via processing receipts (database contract §6).
- **In Sprint 0001 the consumer's only asynchronous side effect is its processing
  receipt.** The consumer does not create a Task, does not modify the Contact, does
  not send a notification, and does not call any external system. The next-action
  Task is created synchronously in the HTTP transaction. The consumer's
  duplicate-delivery obligation is to not repeat its own side effects, enforced by
  the receipt keyed `(consumer_name, event_id)`: duplicates are skipped **only**
  when the receipt status is `processed`; `failed` receipts remain retryable.
- Operator-facing state is a **four-state derivation with strict precedence** —
  `processed`, `failed` (with `failure_stage` = publication | consumer), `published`,
  `pending` — mutually exclusive by construction (database contract §7).
- Rows are never deleted in the slice (retention/pruning is a later, documented
  decision).
- Ordering: the publisher processes claimable rows in `seq` order. Under concurrent
  transactions, `seq` assignment order and commit order can differ; the publisher
  tolerates this (database contract §5) and consumers must not assume gap-free
  sequences.

---

## 3. Relationship summary

```
Tenant 1 ──── * Membership * ──── 1 User
Tenant 1 ──── * Company
Tenant 1 ──── * Contact          Contact * ──── 1 Company         (same tenant, composite FK; required)
Tenant 1 ──── * Interaction      Interaction * ──── 1 Contact     (same tenant, composite FK)
Tenant 1 ──── * Task             Task * ──── 1 Contact            (same tenant, composite FK)
                                 Task 1 ──── 1 Interaction        (same tenant; exactly one per interaction in this slice)
Tenant 1 ──── * Audit event      (references records logically via record_type + record_id)
Tenant 1 ──── * Outbox event     Outbox event * ──── 1 aggregate row (tenant_id + aggregate_type + aggregate_id)
                                 Consumer receipt * ──── 1 Outbox event (composite FK tenant_id + event_id)
```

All actor references on tenant-owned rows (`created_by`, `assigned_to`,
`actor_user_id`) are composite FKs `(tenant_id, <user column>)` targeting
Membership `(tenant_id, user_id)` — so every recorded actor is provably a member of
the row's tenant, and active-ness at write time is rechecked inside the transaction
(§2.3). Membership rows are never deleted (only revoked), which keeps these
references valid for all history.

The chain **Interaction → Outbox event → Consumer receipt** is directly queryable
with ordinary SQL joins; the exact join path is shown in database contract §7.

---

## 4. The log-interaction write set (cross-reference)

The slice's core behavior touches exactly five writes, which must commit atomically
(preceded by the `withTenantWrite` membership/tenant recheck as statement zero):

1. Insert Interaction (`occurred_at` = server transaction time).
2. Update Contact.`last_contacted_at` (forward-only).
3. Insert exactly one next-action Task (`due_on` date, linked to the Interaction,
   status `open`, title generated per Node P's outcome→title rules).
4. Append Audit event (`action = 'interaction.logged'`).
5. Append Outbox event (`event_type = 'interaction.logged'`,
   `aggregate_type = 'interaction'`, `aggregate_id = interaction.id`,
   `aggregate_version = 1`; payload per Node E's envelope schema with
   envelope `event_id` = outbox row `id`).

The transaction boundary, the idempotency-key mechanism (scoped to
tenant + actor + operation + key), the claim-guarded outbox publication protocol, the
consumer-receipt lifecycle, and the four-state derivation are specified in
`docs/specs/database-contract.md`.
