# Domain Model — First Vertical Slice (Sprint 0001, Node D)

Status: contract document for Sprint 0001. Documentation only; no runnable code.
Companion document: `docs/specs/database-contract.md` (PostgreSQL specifics, transaction
boundary, idempotency storage, illustrative DDL).

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

(The idempotency-key storage row, defined in the database contract, is also
tenant-owned and carries `tenant_id`; it is request-processing storage, not a tenth
domain object.)

**Isolation rule.** No query, mutation, or event emission may address a tenant-owned
row without an explicit `tenant_id` predicate. Cross-tenant references are structurally
impossible: all foreign keys between tenant-owned rows are composite
`(tenant_id, <id>)` keys (see database contract, "Key and index conventions"), so a row
in tenant A can never reference a row in tenant B even if application code is buggy.

**Identifier rule.** All primary identifiers are UUIDs generated server-side. Clients
never mint IDs for authoritative records.

**Timestamp rule.** All timestamps are UTC `timestamptz`. `created_at` is set by the
database at insert. Domain-meaningful times (e.g. when a call actually happened) are
distinct fields (`occurred_at`) supplied through the API.

---

## 2. Objects

### 2.1 Tenant (global)

The unit of data isolation and, later, of external customer onboarding.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| name | text | Display name; non-empty. |
| status | text | `active` \| `suspended`. Slice only uses `active`. |
| created_at | timestamptz | |

Invariants:
- A suspended tenant's members fail authorization for all reads and writes (the check
  lives in the resolve-membership step; the slice seeds only an `active` tenant).

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
- A `deactivated` user fails authentication regardless of dev token.

### 2.3 Membership (tenant-owned)

The join between User and Tenant; the sole source of tenant access and the anchor for
authorization.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| user_id | uuid | FK → User. |
| role | text | `owner` \| `member`. Slice treats both as full read/write within the tenant; the field exists so authorization is enforceable and extensible. |
| status | text | `active` \| `revoked`. |
| created_at | timestamptz | |

Invariants:
- At most one Membership per `(tenant_id, user_id)`.
- Authorization rule for the slice: a request may touch a tenant-owned row **iff** the
  authenticated user holds an `active` Membership in that row's `tenant_id`. There is
  no cross-tenant read or write under any role.
- Revoking a membership immediately removes access; no data moves or is deleted.

### 2.4 Company (tenant-owned)

An organization the salesperson sells to.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| name | text | Non-empty. |
| created_by | uuid | FK → User (must have been a member at creation time; recorded for provenance). |
| created_at | timestamptz | |
| updated_at | timestamptz | Maintained on every mutation. |

Invariants:
- `(tenant_id, name)` is unique (case-insensitive) in the slice to keep the demo data
  clean; relaxing this later is a forward-only migration, not a contract break.

### 2.5 Contact (tenant-owned)

A person, optionally attached to a Company.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| company_id | uuid, nullable | Composite FK → Company `(tenant_id, company_id)`. Null = unaffiliated contact. |
| full_name | text | Non-empty. |
| email | text, nullable | No uniqueness constraint in the slice (real-world duplicates exist; dedup is a later feature). |
| phone | text, nullable | |
| last_contacted_at | timestamptz, nullable | **Derived-but-authoritative** field: updated inside the log-interaction transaction. Null until first interaction. |
| created_by | uuid | FK → User. |
| created_at | timestamptz | |
| updated_at | timestamptz | |

Invariants:
- If `company_id` is set, the Company belongs to the same tenant (enforced by the
  composite FK, not just application code).
- `last_contacted_at` only moves forward: it is set to
  `greatest(current value, interaction.occurred_at)` inside the log-interaction
  transaction, so replays and out-of-order logging never rewind it.

### 2.6 Interaction (tenant-owned)

An immutable record of a touch with a Contact. The slice supports logging a call with
an outcome and an optional follow-up.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| contact_id | uuid | Composite FK → Contact `(tenant_id, contact_id)`. |
| kind | text | `call` in the slice; field exists so email/meeting capture lands without schema redesign. |
| outcome | text | Non-empty. The canonical value set is validated at the API layer (Node A's contract); the database constrains presence and length, not the enumeration, so the outcome vocabulary can evolve without migrations. |
| notes | text, nullable | Free text. |
| occurred_at | timestamptz | When the call happened (user-supplied, defaults to now at the API layer). |
| created_by | uuid | FK → User; the actor who logged it. |
| created_at | timestamptz | When it was recorded. |

Invariants:
- Interactions are **append-only**: no update or delete in the slice. Corrections are
  future work and will themselves be audited.
- Every Interaction insert is accompanied, in the same transaction, by the contact
  timestamp update, at most one follow-up Task, exactly one Audit event, and exactly
  one Outbox event (see database contract §2).

### 2.7 Task (tenant-owned)

An explicit next action. In the slice, tasks are created as follow-ups from
log-interaction; the model does not preclude standalone tasks later.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| contact_id | uuid | Composite FK → Contact `(tenant_id, contact_id)`. |
| interaction_id | uuid, nullable | Composite FK → Interaction `(tenant_id, interaction_id)`. Set for follow-up tasks; the provenance link that makes "why does this task exist" answerable. |
| title | text | Non-empty (e.g. "Follow up with Jane Doe"). |
| due_at | timestamptz | User-supplied follow-up time. |
| status | text | `open` \| `done` \| `cancelled`. Created as `open`. |
| assigned_to | uuid | FK → User. Slice assigns to the actor who logged the interaction. |
| created_by | uuid | FK → User. |
| created_at | timestamptz | |
| updated_at | timestamptz | |
| completed_at | timestamptz, nullable | Set when status becomes `done`. |

Invariants:
- **Exactly-one-task guarantee:** at most one Task exists per source Interaction,
  enforced by a partial unique index on `(tenant_id, interaction_id)` where
  `interaction_id` is not null. This is the structural backstop that makes both the
  HTTP idempotency guarantee and the duplicate-Kafka-event guarantee provable — even a
  buggy retry path physically cannot create a second follow-up task for the same
  interaction.
- `completed_at` is non-null iff `status = 'done'`.

### 2.8 Audit event (tenant-owned)

The append-only answer to "who did what, to which record, in which tenant, when."

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| actor_user_id | uuid | FK → User. The authenticated actor. |
| action | text | Verb-object string, e.g. `interaction.logged`, `company.created`, `contact.created`, `task.completed`. |
| record_type | text | Logical object name, e.g. `interaction`. |
| record_id | uuid | ID of the primary affected record. |
| occurred_at | timestamptz | Transaction time of the action. |
| details | jsonb | Small structured context (e.g. related task ID, outcome value). Never used as the system of record for the objects themselves. |

Invariants:
- Append-only: no updates, no deletes, ever. (The database contract adds a
  belt-and-braces enforcement note.)
- Written **in the same transaction** as the change it describes — an audited change
  and its audit row are atomic; neither can exist without the other.
- Captures all five required dimensions of the acceptance criteria: actor
  (`actor_user_id`), tenant (`tenant_id`), action (`action`), record
  (`record_type` + `record_id`), time (`occurred_at`).

### 2.9 Outbox event (tenant-owned)

The durable staging row for at-least-once event publication. The **event envelope
content** (field names inside the JSON payload, event types, topic mapping) is Node E's
contract; this model defines only the **row shape** that stores and tracks it.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key; stable identity of the staged event for logging and inspection. |
| seq | bigint | Monotonic insertion sequence (database identity column); the publisher's ordering key. |
| tenant_id | uuid | FK → Tenant. Present on the row even though the envelope also carries tenant scope, so outbox rows are queryable and isolatable like every other tenant-owned row. |
| payload | jsonb | The complete JSON event envelope, opaque to this layer, validated against Node E's JSON Schema at write time by the producing code path. |
| status | text | `pending` \| `published` \| `failed`. Created as `pending`. |
| attempt_count | integer | Publication attempts so far; starts at 0. |
| last_error | text, nullable | Most recent publication error, for inspection. |
| created_at | timestamptz | |
| published_at | timestamptz, nullable | Set when status becomes `published`. |

Invariants:
- Written **in the same transaction** as the business change it announces; a committed
  change always has its event staged, and a rolled-back change never leaks an event.
- Rows are never deleted in the slice (retention/pruning is a later, documented
  decision); `status` + `attempt_count` + `last_error` + `published_at` make the full
  publication path inspectable, per the slice's acceptance criteria.
- At-least-once semantics: a crash between Kafka publish and `status = 'published'`
  causes re-publication. That is by design; consumers are idempotent (charter
  invariant 4), and the exactly-one-task backstop in §2.7 absorbs duplicates.
- Ordering: the publisher processes rows in `seq` order. Note that under concurrent
  transactions, `seq` assignment order and commit order can differ (a lower `seq` can
  become visible after a higher one); the publisher must tolerate this (details in the
  database contract §5), and consumers must not assume gap-free sequences.

---

## 3. Relationship summary

```
Tenant 1 ──── * Membership * ──── 1 User
Tenant 1 ──── * Company
Tenant 1 ──── * Contact          Contact * ──── 0..1 Company      (same tenant, composite FK)
Tenant 1 ──── * Interaction      Interaction * ──── 1 Contact     (same tenant, composite FK)
Tenant 1 ──── * Task             Task * ──── 1 Contact            (same tenant, composite FK)
                                 Task 0..1 ──── 1 Interaction     (same tenant; ≤1 task per interaction)
Tenant 1 ──── * Audit event      (references records logically via record_type + record_id)
Tenant 1 ──── * Outbox event     (references records inside the JSON envelope; Node E's contract)
```

`created_by` / `actor_user_id` / `assigned_to` reference the global User table directly
(plain FK, not composite), because Users are global; the tenant-validity of the actor
is established by the Membership check in the request pipeline, and the audit row
freezes who acted regardless of later membership revocation.

---

## 4. The log-interaction write set (cross-reference)

The slice's core behavior touches exactly five writes, which must commit atomically:

1. Insert Interaction.
2. Update Contact.`last_contacted_at` (forward-only).
3. Insert follow-up Task (linked to the Interaction).
4. Append Audit event (`action = 'interaction.logged'`).
5. Append Outbox event (payload per Node E's envelope schema).

The transaction boundary, the idempotency-key mechanism that makes duplicate HTTP
requests safe, and the illustrative DDL are specified in
`docs/specs/database-contract.md`.
