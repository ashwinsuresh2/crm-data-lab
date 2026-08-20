# Domain Model — First Vertical Slice (Sprint 0001, Node D)

Status: contract document for Sprint 0001, remediation pass after barrier review.
Documentation only; no runnable code.
Companion document: `docs/specs/database-contract.md` (PostgreSQL specifics, transaction
boundary, idempotency storage, outbox publication, illustrative DDL).

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
they are processing storage, not additional domain objects.)

**Isolation rule.** No query, mutation, or event emission may address a tenant-owned
row without an explicit `tenant_id` predicate. Cross-tenant references are structurally
impossible: all foreign keys between tenant-owned rows are composite
`(tenant_id, <id>)` keys (see database contract, "Key and index conventions"), so a row
in tenant A can never reference a row in tenant B even if application code is buggy.

**Tenant-valid actor rule.** Wherever a tenant-owned row references a user
(`created_by`, `assigned_to`, `actor_user_id`), the reference is a composite foreign
key `(tenant_id, user_id)` targeting Membership — not a plain FK to the global User
table. A tenant-owned row therefore cannot name a user who was never a member of that
tenant. (The FK proves membership *existence*; the *active* status of that membership
at action time is enforced by the request pipeline — see Membership invariants.)

**Identifier rule.** All primary identifiers are UUIDs generated server-side. Clients
never mint IDs for authoritative records.

**Timestamp rule.** All timestamps are UTC `timestamptz`. `created_at` is set by the
database at insert. In this slice, `Interaction.occurred_at` is also assigned
server-side at write time (clients do not supply it). Calendar-date fields
(`Task.due_on`) use SQL `date` and are interpreted against the tenant's
`operating_timezone`.

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
  forever. Revocation immediately removes access (pipeline check); it does not touch
  data.
- Documented tradeoff: the composite actor FK proves the actor *was granted*
  membership in the tenant; it does not prove the membership was `active` at write
  time (FKs cannot see `status`). Active-ness is enforced by the request pipeline on
  every request, and the audit trail records who acted regardless of later revocation.

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
an outcome and a mandatory follow-up.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| contact_id | uuid | Composite FK → Contact `(tenant_id, contact_id)`. |
| kind | text | `call` in the slice; field exists so email/meeting capture lands without schema redesign. |
| outcome | text | Non-empty. Values come from the **product-owned closed vocabulary defined in Node P's contract**; validation model is specified in the database contract (§1 item 5). |
| notes | text, nullable | Free text. |
| occurred_at | timestamptz | **Assigned server-side at write time** (transaction time). Not client-supplied in this slice; backdating is future work and will itself be audited. |
| created_by | uuid | Composite FK `(tenant_id, created_by)` → Membership `(tenant_id, user_id)`; the actor who logged it. |
| created_at | timestamptz | When it was recorded (equals `occurred_at` in this slice by construction; kept as separate fields because they diverge once backdating exists). |

Invariants:
- Interactions are **append-only**: no update or delete in the slice. Corrections are
  future work and will themselves be audited.
- **Every successful Interaction creates exactly one linked open Task.** The follow-up
  is not optional. Every Interaction insert is accompanied, in the same transaction,
  by the contact timestamp update, exactly one follow-up Task, exactly one Audit
  event, and exactly one Outbox event (see database contract §2).

### 2.7 Task (tenant-owned)

An explicit next action. In the slice, every task is the mandatory follow-up of exactly
one Interaction; the model does not preclude standalone tasks later.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| contact_id | uuid | Composite FK → Contact `(tenant_id, contact_id)`. |
| interaction_id | uuid | Composite FK → Interaction `(tenant_id, interaction_id)`. The provenance link that makes "why does this task exist" answerable. Nullable in schema only to leave room for future standalone tasks; in Sprint 0001 every task has it set. |
| title | text | Non-empty (e.g. "Follow up with Jane Doe"). |
| due_on | date | The selected follow-up **date** (SQL `date`, not a timestamp). Interpreted against the tenant's `operating_timezone` (e.g. "due today", overdue-at-end-of-day). Client selects the date; server stores it as-is. |
| status | text | `open` \| `done` — exactly these two states in this slice. Created as `open`. |
| assigned_to | uuid | Composite FK `(tenant_id, assigned_to)` → Membership `(tenant_id, user_id)`. Slice assigns to the actor who logged the interaction. |
| created_by | uuid | Composite FK `(tenant_id, created_by)` → Membership `(tenant_id, user_id)`. |
| created_at | timestamptz | |
| updated_at | timestamptz | |
| completed_at | timestamptz, nullable | Set when status becomes `done`. |

Invariants:
- **Exactly-one-task guarantee:** the log-interaction transaction creates exactly one
  Task per Interaction (existence), and a partial unique index on
  `(tenant_id, interaction_id)` enforces at-most-one (uniqueness). Together:
  exactly one. The index is the structural backstop that makes the HTTP idempotency
  guarantee provable — even a buggy retry path physically cannot create a second
  follow-up task for the same interaction. (The Kafka consumer never creates tasks
  at all — see §2.9 and database contract §5–6 — so duplicate event delivery is not a
  task-duplication vector in the first place.)
- `completed_at` is non-null iff `status = 'done'`.

### 2.8 Audit event (tenant-owned)

The append-only answer to "who did what, to which record, in which tenant, when."

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key. |
| tenant_id | uuid | FK → Tenant. |
| actor_user_id | uuid | Composite FK `(tenant_id, actor_user_id)` → Membership `(tenant_id, user_id)`. The authenticated actor, provably a member of the tenant. |
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
- Because Membership rows are never deleted (§2.3), audit rows remain structurally
  valid even after the actor's membership is revoked.

### 2.9 Outbox event (tenant-owned)

The durable staging row for at-least-once event publication. The **event envelope
content** (field names inside the JSON payload, event types, topic mapping) is Node E's
contract; this model defines only the **row shape** that stores and tracks it.

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key; stable identity of the staged event for logging, receipts, and inspection. |
| seq | bigint | Monotonic insertion sequence (database identity column); the publisher's processing-order key. |
| tenant_id | uuid | FK → Tenant. Present on the row even though the envelope also carries tenant scope, so outbox rows are queryable and isolatable like every other tenant-owned row. |
| payload | jsonb | The complete JSON event envelope, opaque to this layer, validated against Node E's JSON Schema at write time by the producing code path. |
| status | text | `pending` \| `published` \| `failed`. Created as `pending`. |
| claimed_by | text, nullable | Identity of the publisher worker holding the current claim lease. |
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
  publish, and a short acknowledge transaction (database contract §5). A crash between
  publish and acknowledge yields re-publication after the lease expires — that is
  at-least-once by design, and consumers are idempotent via processing receipts
  (database contract §6).
- The Kafka consumer performs **its own** side effects only (e.g. reminder/processing
  records); it never creates Tasks — the follow-up Task is created synchronously in
  the HTTP transaction. The consumer's duplicate-delivery obligation is to not repeat
  its own side effects, enforced by the consumer-receipt table keyed by
  `(consumer_name, event_id)`.
- Inspectable end-to-end state is derived, not stored in one column:
  **pending** = outbox `status = 'pending'`; **published** = outbox
  `status = 'published'`; **processed** = a consumer receipt exists for the event
  (mapping made explicit in database contract §7).
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
Tenant 1 ──── * Outbox event     (references records inside the JSON envelope; Node E's contract)
```

All actor references on tenant-owned rows (`created_by`, `assigned_to`,
`actor_user_id`) are composite FKs `(tenant_id, <user column>)` targeting
Membership `(tenant_id, user_id)` — so every recorded actor is provably a member of
the row's tenant. Membership rows are never deleted (only revoked), which keeps these
references valid for all history.

---

## 4. The log-interaction write set (cross-reference)

The slice's core behavior touches exactly five writes, which must commit atomically:

1. Insert Interaction (`occurred_at` = server transaction time).
2. Update Contact.`last_contacted_at` (forward-only).
3. Insert exactly one follow-up Task (`due_on` date, linked to the Interaction,
   status `open`).
4. Append Audit event (`action = 'interaction.logged'`).
5. Append Outbox event (payload per Node E's envelope schema).

The transaction boundary, the idempotency-key mechanism (scoped to
tenant + actor + operation + key) that makes duplicate HTTP requests safe, the
lease-based outbox publication protocol, and the consumer-receipt mechanism are
specified in `docs/specs/database-contract.md`.
