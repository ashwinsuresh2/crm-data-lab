# Database Contract — First Vertical Slice (Sprint 0001, Node D)

Status: contract document for Sprint 0001. Documentation only; the DDL below is
**illustrative** and becomes real numbered migrations in Sprint 0002.
Companion document: `docs/specs/domain-model.md` (objects, fields, invariants,
tenant-scoping rules).

Target: PostgreSQL (single authoritative instance; charter invariant 1). All access
goes through the CRM API; the browser and workers never write to PostgreSQL directly
except the API service and the outbox publisher/consumer worker, which are backend
components behind the API boundary.

---

## 1. Key and index conventions

1. **Primary keys** are `uuid`, generated server-side (`gen_random_uuid()` via
   `pgcrypto`, or application-generated UUIDv7 later if insert locality matters —
   either satisfies this contract; Sprint 0002 picks one and records it).
2. **Tenant anchor:** every tenant-owned table declares
   `tenant_id uuid NOT NULL REFERENCES tenant(id)` and a
   `UNIQUE (tenant_id, id)` constraint. The unique constraint exists solely to be the
   target of composite foreign keys.
3. **Composite foreign keys:** any FK between two tenant-owned tables references
   `(tenant_id, id)` of the parent, with the child's own `tenant_id` participating.
   This makes cross-tenant references a constraint violation, not merely an
   application-layer bug. Example: `contact (tenant_id, company_id) REFERENCES
   company (tenant_id, id)`.
4. **Secondary indexes lead with `tenant_id`** (e.g. `(tenant_id, contact_id,
   occurred_at DESC)`), matching the rule that every query carries a tenant predicate.
5. **Enumerated values** use `text` + `CHECK` constraints, not Postgres `ENUM` types
   (cheaper to evolve with forward-only migrations). Where the value set is expected
   to grow product-side (Interaction.outcome), the DB checks presence/length only and
   the API layer owns the vocabulary.
6. **Timestamps** are `timestamptz`, UTC. `created_at DEFAULT now()`.
7. **Append-only tables** (`interaction`, `audit_event`): no UPDATE/DELETE statements
   in application code; Sprint 0002 may add a `REVOKE UPDATE, DELETE` on these tables
   from the application role (recommended) — either way the contract is append-only.
8. **Row-level security seam:** the slice enforces isolation via composite FKs +
   mandatory tenant predicates + tenant-isolation tests. Postgres RLS is a documented
   future hardening step, not required for the slice; nothing in this schema blocks
   enabling it later.

---

## 2. The log-interaction transaction boundary

The slice's core behavior is one atomic PostgreSQL transaction. **All of the following
commit together or not at all** (`READ COMMITTED` is sufficient; correctness comes
from constraints and row locks, not isolation level):

```
BEGIN;

-- (0) Idempotency reservation — same transaction, see §3.
INSERT INTO idempotency_key (tenant_id, key, request_hash, status)
VALUES ($tenant, $key, $hash, 'in_progress')
ON CONFLICT (tenant_id, key) DO NOTHING;
-- if 0 rows inserted → this is a replay or a concurrent duplicate: see §3 flow.

-- (1) Insert the interaction.
INSERT INTO interaction (id, tenant_id, contact_id, kind, outcome, notes,
                         occurred_at, created_by) VALUES (...);

-- (2) Forward-only update of the contact's last-contacted timestamp.
UPDATE contact
   SET last_contacted_at = GREATEST(COALESCE(last_contacted_at, '-infinity'), $occurred_at),
       updated_at        = now()
 WHERE tenant_id = $tenant AND id = $contact_id;

-- (3) Create the follow-up task (≤1 per interaction, enforced by unique index).
INSERT INTO task (id, tenant_id, contact_id, interaction_id, title, due_at,
                  status, assigned_to, created_by) VALUES (..., 'open', ...);

-- (4) Append the audit record.
INSERT INTO audit_event (id, tenant_id, actor_user_id, action, record_type,
                         record_id, occurred_at, details)
VALUES (..., 'interaction.logged', 'interaction', $interaction_id, now(),
        jsonb_build_object('task_id', $task_id, 'outcome', $outcome));

-- (5) Append the outbox event (payload = Node E's JSON envelope).
INSERT INTO outbox_event (id, tenant_id, payload, status)
VALUES (..., $envelope_jsonb, 'pending');

-- (6) Record the result on the idempotency row before commit.
UPDATE idempotency_key
   SET status = 'completed', interaction_id = $interaction_id, task_id = $task_id,
       completed_at = now()
 WHERE tenant_id = $tenant AND key = $key;

COMMIT;
```

Consequences:

- A committed interaction **always** has its contact-timestamp update, its task, its
  audit row, its outbox row, and its completed idempotency row. A rollback leaves
  none of them. There is no state in which the timeline, the task list, the audit
  trail, and the event stream disagree about whether the interaction happened.
- Authorization (active membership in `$tenant`, contact belongs to `$tenant`) is
  checked before the transaction; the composite FKs re-enforce tenant consistency
  inside it.
- If the follow-up is optional in the API contract and omitted, step (3) is skipped
  and the idempotency row records a null `task_id`; everything else is unchanged.
  (Node A owns whether follow-up is required; this contract supports both.)

---

## 3. Idempotency-key storage

**Purpose:** a duplicate HTTP request with the same idempotency key must produce one
interaction and one task, and the replay must receive the same identifiers as the
original.

**Uniqueness scope:** `(tenant_id, key)`. Keys are opaque client-supplied strings
(bounded length, e.g. ≤ 200 chars); two tenants using the same key never collide, and
the row itself is tenant-owned like everything else.

| Column | Type | Notes |
|---|---|---|
| tenant_id | uuid | FK → tenant. |
| key | text | Client-supplied idempotency key. |
| request_hash | text | Hash of the canonical request body; detects "same key, different payload" misuse. |
| status | text | `in_progress` \| `completed`. |
| interaction_id | uuid, nullable | Result: the created interaction. |
| task_id | uuid, nullable | Result: the created follow-up task (null if none). |
| created_at | timestamptz | |
| completed_at | timestamptz, nullable | |

Primary key: `(tenant_id, key)`.

**Flow (provably one interaction, one task):**

1. Inside the transaction, `INSERT ... ON CONFLICT (tenant_id, key) DO NOTHING`.
2. **Row inserted** → this transaction owns the key; proceed with writes (1)–(6).
3. **No row inserted** → a prior or concurrent request holds the key. Read the
   existing row:
   - `status = 'completed'` and `request_hash` matches → **replay**: return the stored
     `interaction_id` and `task_id` (the same response as the original), performing no
     writes. This is what the API returns on replay.
   - `request_hash` differs → key reuse with a different payload; surface as a client
     error (exact HTTP status is Node A's contract). No writes.
   - `status = 'in_progress'` → a concurrent duplicate is in flight. Note that under
     `ON CONFLICT`, the second transaction **blocks** on the first's uncommitted
     insert until it commits or rolls back, then re-evaluates — so in practice the
     duplicate observes either `completed` (replay) or, after a rollback, a free key
     (retry proceeds). A row stuck `in_progress` after a crash mid-transaction cannot
     exist, because the row itself rolls back with the transaction.

**Why the guarantee holds:** the key row, the interaction, and the task are created in
*one* transaction, and the key is unique per tenant. Two requests with the same key
cannot both insert the key row, so at most one can perform the business writes. As a
second, independent backstop, the partial unique index on
`task (tenant_id, interaction_id)` makes a second follow-up task for the same
interaction impossible even if a future code path mishandles retries — and it is also
what makes the *Kafka-side* duplicate-delivery guarantee cheap for the consumer.

Retention: rows may be pruned after a documented window (e.g. 24–72 h) in a later
sprint; the slice keeps all rows.

---

## 4. Illustrative DDL for the core tables

Reference shape only — Sprint 0002 turns this into numbered, tested migrations and may
adjust names/types within the invariants of this contract.

```sql
-- Global tables ------------------------------------------------------------

CREATE TABLE tenant (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app_user (                        -- "user" is a reserved word
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email         text NOT NULL,
    display_name  text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 200),
    status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','deactivated')),
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX app_user_email_uq ON app_user (lower(email));
-- Credential seam: a future user_credential table keyed by user_id attaches here.

-- Tenant-owned tables ------------------------------------------------------

CREATE TABLE membership (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenant(id),
    user_id     uuid NOT NULL REFERENCES app_user(id),
    role        text NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, user_id),
    UNIQUE (tenant_id, id)
);

CREATE TABLE company (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenant(id),
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 300),
    created_by  uuid NOT NULL REFERENCES app_user(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id)
);
CREATE UNIQUE INDEX company_tenant_name_uq ON company (tenant_id, lower(name));

CREATE TABLE contact (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenant(id),
    company_id         uuid,
    full_name          text NOT NULL CHECK (length(full_name) BETWEEN 1 AND 300),
    email              text,
    phone              text,
    last_contacted_at  timestamptz,
    created_by         uuid NOT NULL REFERENCES app_user(id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, company_id) REFERENCES company (tenant_id, id)
);
CREATE INDEX contact_tenant_company_ix ON contact (tenant_id, company_id);

CREATE TABLE interaction (                     -- append-only
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    contact_id   uuid NOT NULL,
    kind         text NOT NULL CHECK (kind IN ('call')),   -- widened by future migration
    outcome      text NOT NULL CHECK (length(outcome) BETWEEN 1 AND 100),
    notes        text,
    occurred_at  timestamptz NOT NULL,
    created_by   uuid NOT NULL REFERENCES app_user(id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, contact_id) REFERENCES contact (tenant_id, id)
);
CREATE INDEX interaction_timeline_ix ON interaction (tenant_id, contact_id, occurred_at DESC);

CREATE TABLE task (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    contact_id      uuid NOT NULL,
    interaction_id  uuid,
    title           text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    due_at          timestamptz NOT NULL,
    status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','cancelled')),
    assigned_to     uuid NOT NULL REFERENCES app_user(id),
    created_by      uuid NOT NULL REFERENCES app_user(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, contact_id)     REFERENCES contact (tenant_id, id),
    FOREIGN KEY (tenant_id, interaction_id) REFERENCES interaction (tenant_id, id),
    CHECK ((status = 'done') = (completed_at IS NOT NULL))
);
-- The exactly-one-task backstop:
CREATE UNIQUE INDEX task_one_per_interaction_uq
    ON task (tenant_id, interaction_id) WHERE interaction_id IS NOT NULL;
CREATE INDEX task_open_by_due_ix
    ON task (tenant_id, due_at) WHERE status = 'open';

CREATE TABLE audit_event (                     -- append-only
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES tenant(id),
    actor_user_id  uuid NOT NULL REFERENCES app_user(id),
    action         text NOT NULL CHECK (length(action) BETWEEN 1 AND 100),
    record_type    text NOT NULL CHECK (length(record_type) BETWEEN 1 AND 100),
    record_id      uuid NOT NULL,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    details        jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (tenant_id, id)
);
CREATE INDEX audit_event_tenant_time_ix  ON audit_event (tenant_id, occurred_at DESC);
CREATE INDEX audit_event_record_ix       ON audit_event (tenant_id, record_type, record_id);

CREATE TABLE outbox_event (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq            bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id      uuid NOT NULL REFERENCES tenant(id),
    payload        jsonb NOT NULL,             -- Node E's JSON envelope, schema-validated at write
    status         text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','published','failed')),
    attempt_count  integer NOT NULL DEFAULT 0,
    last_error     text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    published_at   timestamptz,
    UNIQUE (tenant_id, id),
    CHECK ((status = 'published') = (published_at IS NOT NULL))
);
CREATE UNIQUE INDEX outbox_event_seq_uq ON outbox_event (seq);
CREATE INDEX outbox_event_pending_ix ON outbox_event (seq) WHERE status = 'pending';

CREATE TABLE idempotency_key (
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    key             text NOT NULL CHECK (length(key) BETWEEN 1 AND 200),
    request_hash    text NOT NULL,
    status          text NOT NULL DEFAULT 'in_progress'
                    CHECK (status IN ('in_progress','completed')),
    interaction_id  uuid,
    task_id         uuid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    PRIMARY KEY (tenant_id, key),
    FOREIGN KEY (tenant_id, interaction_id) REFERENCES interaction (tenant_id, id),
    FOREIGN KEY (tenant_id, task_id)        REFERENCES task (tenant_id, id)
);
```

---

## 5. Outbox publication contract (database side)

Node E owns the envelope, topics, and Kafka client boundary. The database-side
contract the publisher relies on:

- **Claiming:** the publisher selects work with
  `SELECT ... FROM outbox_event WHERE status = 'pending' ORDER BY seq
  FOR UPDATE SKIP LOCKED LIMIT n`, publishes to Kafka, then sets
  `status = 'published'`, `published_at = now()`, incrementing `attempt_count`; on
  failure it records `last_error`, increments `attempt_count`, and leaves the row
  `pending` (or `failed` after a policy-defined attempt ceiling — policy is Node E's).
- **At-least-once:** a crash after Kafka publish but before the status update
  re-publishes the same envelope on restart. This is intended; consumers are
  idempotent, and the payload's stable event ID (Node E) plus the
  `task_one_per_interaction_uq` index make duplicate deliveries side-effect-free.
- **Ordering caveat:** `seq` is assigned at insert, but concurrent transactions can
  commit out of `seq` order, so a lower-`seq` row may become visible to the publisher
  after a higher one has been published. The publisher must not treat `seq` as
  gap-free or strictly commit-ordered; it is a stable *processing* order for rows
  visible at claim time. Strict per-key ordering, if required, is provided by Kafka
  partitioning keys (Node E's contract), not by this table.
- **Inspectability:** `status`, `attempt_count`, `last_error`, `created_at`,
  `published_at` together satisfy the slice requirement that the complete path be
  inspectable; no row is deleted in the slice.

---

## 6. Migration conventions for Sprint 0002 (tooling-agnostic)

1. **Forward-only.** No down migrations. Reversal is a new forward migration.
2. **Numbered and ordered.** `NNNN_short_description.sql` (zero-padded, strictly
   increasing, no reuse of numbers, no edits to a migration after it has merged —
   fixes are new migrations).
3. **One concern per migration.** Schema change and any required data backfill may
   share a migration only when they must be atomic; otherwise split.
4. **Tracked in-database.** A `schema_migrations` (or tool-equivalent) table records
   applied versions; application startup fails fast on unapplied migrations.
5. **Tested.** CI must (a) apply the full chain to an empty database, (b) apply new
   migrations on top of a database built from the previously merged chain, and
   (c) run the schema-dependent integration, tenant-isolation, and idempotency tests
   against the migrated schema.
6. **Transactional where possible.** Each migration runs in a transaction; statements
   that cannot (e.g. `CREATE INDEX CONCURRENTLY`) are isolated in their own migration
   and documented. At slice scale, plain `CREATE INDEX` in-transaction is fine.
7. **Additive bias.** Prefer add-column/backfill/constrain sequences over destructive
   changes; renames go through add → dual-write → drop across releases once real data
   exists.

---

## 7. Acceptance self-check (traceability)

| Requirement | Where satisfied |
|---|---|
| Every tenant-owned row carries `tenant_id` | §1 conventions; every tenant-owned table in §4 has `tenant_id NOT NULL` (membership, company, contact, interaction, task, audit_event, outbox_event, idempotency_key). |
| Transaction covers all five writes | §2: interaction insert, contact update, task insert, audit append, outbox append (plus idempotency reservation) in one `BEGIN…COMMIT`. |
| Duplicate HTTP request, same key → one interaction, one task | §3 unique `(tenant_id, key)` + same-transaction result recording; backstop `task_one_per_interaction_uq` in §4. |
| Audit captures actor, tenant, action, record, time | §4 `audit_event`: `actor_user_id`, `tenant_id`, `action`, `record_type`+`record_id`, `occurred_at`. |
| Outbox supports at-least-once + inspectable state | §4 `outbox_event` columns; §5 claiming/at-least-once/inspectability contract. |
