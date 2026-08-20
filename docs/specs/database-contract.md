# Database Contract — First Vertical Slice (Sprint 0001, Node D)

Status: contract document for Sprint 0001, remediation pass after barrier review.
Documentation only; the DDL below is **illustrative** and becomes real numbered
migrations in Sprint 0002.
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
   **Actor references** (`created_by`, `assigned_to`, `actor_user_id`) follow the same
   pattern but target `membership (tenant_id, user_id)` instead of the global user
   table, so a tenant-owned row can only name a user who holds a membership row in
   that tenant. Documented tradeoff: the FK proves the membership row *exists*, not
   that its `status` was `active` at write time (FKs cannot see status); active-ness
   is enforced by the request pipeline on every request, and membership rows are
   never deleted (only revoked) so historical references stay valid.
4. **Secondary indexes lead with `tenant_id`** (e.g. `(tenant_id, contact_id,
   occurred_at DESC)`), matching the rule that every query carries a tenant predicate.
5. **Enumerated values** use `text` + `CHECK` constraints, not Postgres `ENUM` types
   (cheaper to evolve with forward-only migrations). `interaction.outcome` is special:
   its values are validated against the **product-defined closed vocabulary owned by
   Node P's contract**. Chosen enforcement: **API-layer validation against Node P's
   list**, with the database constraining presence and length only — so vocabulary
   evolution is a product-contract change, not a schema migration. (If Node P later
   requires DB-level enforcement, a `CHECK` mirroring the list can be added by
   forward migration.)
6. **Timestamps** are `timestamptz`, UTC, with `created_at DEFAULT now()`.
   `interaction.occurred_at` is assigned server-side at write time in this slice.
   Calendar dates (`task.due_on`) use SQL `date` and are interpreted against
   `tenant.operating_timezone`.
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
from constraints and row locks, not isolation level). The follow-up Task is
**mandatory**: every successful log-interaction creates exactly one open Task.

```
BEGIN;

-- (0) Idempotency reservation — same transaction, see §3.
INSERT INTO idempotency_key (tenant_id, actor_user_id, operation, key, request_hash, status)
VALUES ($tenant, $actor, 'log-interaction', $key, $hash, 'in_progress')
ON CONFLICT (tenant_id, actor_user_id, operation, key) DO NOTHING;
-- if 0 rows inserted → this is a replay or a concurrent duplicate: see §3 flow.

-- (1) Insert the interaction; occurred_at is server-assigned transaction time.
INSERT INTO interaction (id, tenant_id, contact_id, kind, outcome, notes,
                         occurred_at, created_by)
VALUES (..., now(), $actor);

-- (2) Forward-only update of the contact's last-contacted timestamp.
UPDATE contact
   SET last_contacted_at = GREATEST(COALESCE(last_contacted_at, '-infinity'), $occurred_at),
       updated_at        = now()
 WHERE tenant_id = $tenant AND id = $contact_id;

-- (3) Create the mandatory follow-up task (exactly 1; ≤1 enforced by unique index).
INSERT INTO task (id, tenant_id, contact_id, interaction_id, title, due_on,
                  status, assigned_to, created_by)
VALUES (..., $due_on_date, 'open', $actor, $actor);

-- (4) Append the audit record.
INSERT INTO audit_event (id, tenant_id, actor_user_id, action, record_type,
                         record_id, occurred_at, details)
VALUES (..., $actor, 'interaction.logged', 'interaction', $interaction_id, now(),
        jsonb_build_object('task_id', $task_id, 'outcome', $outcome));

-- (5) Append the outbox event (payload = Node E's JSON envelope).
INSERT INTO outbox_event (id, tenant_id, payload, status)
VALUES (..., $envelope_jsonb, 'pending');

-- (6) Record the result on the idempotency row before commit.
UPDATE idempotency_key
   SET status = 'completed', interaction_id = $interaction_id, task_id = $task_id,
       completed_at = now()
 WHERE tenant_id = $tenant AND actor_user_id = $actor
   AND operation = 'log-interaction' AND key = $key;

COMMIT;
```

Consequences:

- A committed interaction **always** has its contact-timestamp update, its one open
  task, its audit row, its outbox row, and its completed idempotency row. A rollback
  leaves none of them. There is no state in which the timeline, the task list, the
  audit trail, and the event stream disagree about whether the interaction happened.
- Authorization (active membership in `$tenant`, contact belongs to `$tenant`) is
  checked before the transaction; the composite FKs — including the actor FKs to
  membership — re-enforce tenant consistency inside it.
- This transaction touches only PostgreSQL. It performs no network calls; Kafka
  publication happens later, outside any transaction (§5).

---

## 3. Idempotency-key storage

**Purpose:** a duplicate HTTP request with the same idempotency key must produce one
interaction and one task, and the replay must receive the same identifiers as the
original.

**Uniqueness scope:** `(tenant_id, actor_user_id, operation, key)`. Keys are opaque
client-supplied strings (bounded length, ≤ 200 chars). Scoping by tenant preserves
isolation; scoping by actor and operation means two users — or two different
operations — reusing the same key string never collide. The row is tenant-owned like
everything else.

| Column | Type | Notes |
|---|---|---|
| tenant_id | uuid | FK → tenant. |
| actor_user_id | uuid | Composite FK `(tenant_id, actor_user_id)` → membership `(tenant_id, user_id)`. |
| operation | text | Logical operation name, e.g. `log-interaction`. |
| key | text | Client-supplied idempotency key. |
| request_hash | text | Hash of the canonical request body; detects "same key, different payload" misuse. |
| status | text | `in_progress` \| `completed`. |
| interaction_id | uuid | Result: the created interaction. Non-null on every committed `completed` row. |
| task_id | uuid | Result: the created follow-up task. Non-null on every committed `completed` row (follow-up is mandatory). |
| created_at | timestamptz | |
| completed_at | timestamptz, nullable | |

Primary key: `(tenant_id, actor_user_id, operation, key)`.

**Flow (provably one interaction, one task):**

1. Inside the transaction, `INSERT ... ON CONFLICT (tenant_id, actor_user_id,
   operation, key) DO NOTHING`.
2. **Row inserted** → this transaction owns the key; proceed with writes (1)–(6).
3. **No row inserted** → a prior or concurrent request holds the key. Read the
   existing row:
   - `status = 'completed'` and `request_hash` matches → **replay**: return the stored
     `interaction_id` and `task_id` (the same response as the original), performing no
     writes.
   - `request_hash` differs → key reuse with a different payload; surface as a client
     error (exact HTTP status is Node A's contract). No writes.
   - `status = 'in_progress'` → a concurrent duplicate is in flight. Under
     `ON CONFLICT`, the second transaction **blocks** on the first's uncommitted
     insert until it commits or rolls back, then re-evaluates — so in practice the
     duplicate observes either `completed` (replay) or, after a rollback, a free key
     (retry proceeds). A row stuck `in_progress` after a crash mid-transaction cannot
     exist, because the row itself rolls back with the transaction.

**Why the guarantee holds:** the key row, the interaction, and the task are created in
*one* transaction, and the key is unique per (tenant, actor, operation). Two requests
with the same scoped key cannot both insert the key row, so at most one can perform
the business writes. As a second, independent backstop, the partial unique index on
`task (tenant_id, interaction_id)` makes a second follow-up task for the same
interaction impossible even if a future HTTP retry path mishandles the key protocol.
(The Kafka consumer never creates tasks — §6 — so it is not a duplication vector.)

Retention: rows may be pruned after a documented window (e.g. 24–72 h) in a later
sprint; the slice keeps all rows.

---

## 4. Illustrative DDL for the core tables

Reference shape only — Sprint 0002 turns this into numbered, tested migrations and may
adjust names/types within the invariants of this contract.

```sql
-- Global tables ------------------------------------------------------------

CREATE TABLE tenant (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name                text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
    operating_timezone  text NOT NULL CHECK (length(operating_timezone) BETWEEN 1 AND 64),
                        -- IANA identifier, e.g. 'America/New_York'; validated at API layer
    status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended')),
    created_at          timestamptz NOT NULL DEFAULT now()
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
    UNIQUE (tenant_id, user_id),   -- target of all composite actor FKs below
    UNIQUE (tenant_id, id)
);
-- Membership rows are never deleted, only status-revoked (keeps actor FKs valid).

CREATE TABLE company (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenant(id),
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 300),
                -- deliberately NOT unique per tenant: duplicate names are allowed
    created_by  uuid NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, created_by) REFERENCES membership (tenant_id, user_id)
);
CREATE INDEX company_tenant_name_ix ON company (tenant_id, lower(name));

CREATE TABLE contact (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenant(id),
    company_id         uuid NOT NULL,          -- required in Sprint 0001
    full_name          text NOT NULL CHECK (length(full_name) BETWEEN 1 AND 300),
    email              text,
    phone              text,
    last_contacted_at  timestamptz,
    created_by         uuid NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, company_id) REFERENCES company (tenant_id, id),
    FOREIGN KEY (tenant_id, created_by) REFERENCES membership (tenant_id, user_id)
);
CREATE INDEX contact_tenant_company_ix ON contact (tenant_id, company_id);

CREATE TABLE interaction (                     -- append-only
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    contact_id   uuid NOT NULL,
    kind         text NOT NULL CHECK (kind IN ('call')),   -- widened by future migration
    outcome      text NOT NULL CHECK (length(outcome) BETWEEN 1 AND 100),
                 -- values validated at API layer against Node P's closed vocabulary
    notes        text,
    occurred_at  timestamptz NOT NULL DEFAULT now(),       -- server-assigned in this slice
    created_by   uuid NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, contact_id) REFERENCES contact (tenant_id, id),
    FOREIGN KEY (tenant_id, created_by) REFERENCES membership (tenant_id, user_id)
);
CREATE INDEX interaction_timeline_ix ON interaction (tenant_id, contact_id, occurred_at DESC);

CREATE TABLE task (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    contact_id      uuid NOT NULL,
    interaction_id  uuid,        -- set on every Sprint 0001 task; nullable only for future standalone tasks
    title           text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    due_on          date NOT NULL,             -- interpreted in tenant.operating_timezone
    status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done')),
    assigned_to     uuid NOT NULL,
    created_by      uuid NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, contact_id)     REFERENCES contact (tenant_id, id),
    FOREIGN KEY (tenant_id, interaction_id) REFERENCES interaction (tenant_id, id),
    FOREIGN KEY (tenant_id, assigned_to)    REFERENCES membership (tenant_id, user_id),
    FOREIGN KEY (tenant_id, created_by)     REFERENCES membership (tenant_id, user_id),
    CHECK ((status = 'done') = (completed_at IS NOT NULL))
);
-- The exactly-one-task backstop (HTTP-retry safety; the consumer never creates tasks):
CREATE UNIQUE INDEX task_one_per_interaction_uq
    ON task (tenant_id, interaction_id) WHERE interaction_id IS NOT NULL;
CREATE INDEX task_open_by_due_ix
    ON task (tenant_id, due_on) WHERE status = 'open';

CREATE TABLE audit_event (                     -- append-only
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES tenant(id),
    actor_user_id  uuid NOT NULL,
    action         text NOT NULL CHECK (length(action) BETWEEN 1 AND 100),
    record_type    text NOT NULL CHECK (length(record_type) BETWEEN 1 AND 100),
    record_id      uuid NOT NULL,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    details        jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, actor_user_id) REFERENCES membership (tenant_id, user_id)
);
CREATE INDEX audit_event_tenant_time_ix  ON audit_event (tenant_id, occurred_at DESC);
CREATE INDEX audit_event_record_ix       ON audit_event (tenant_id, record_type, record_id);

CREATE TABLE outbox_event (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq               bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id         uuid NOT NULL REFERENCES tenant(id),
    payload           jsonb NOT NULL,          -- Node E's JSON envelope, schema-validated at write
    status            text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','published','failed')),
    claimed_by        text,                    -- publisher worker identity holding the lease
    lease_expires_at  timestamptz,             -- lease lapse time; expired lease => reclaimable
    attempt_count     integer NOT NULL DEFAULT 0,
    last_error        text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    published_at      timestamptz,
    UNIQUE (tenant_id, id),
    CHECK ((status = 'published') = (published_at IS NOT NULL))
);
CREATE UNIQUE INDEX outbox_event_seq_uq ON outbox_event (seq);
CREATE INDEX outbox_event_pending_ix ON outbox_event (seq) WHERE status = 'pending';

CREATE TABLE idempotency_key (
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    actor_user_id   uuid NOT NULL,
    operation       text NOT NULL CHECK (length(operation) BETWEEN 1 AND 100),
    key             text NOT NULL CHECK (length(key) BETWEEN 1 AND 200),
    request_hash    text NOT NULL,
    status          text NOT NULL DEFAULT 'in_progress'
                    CHECK (status IN ('in_progress','completed')),
    interaction_id  uuid,
    task_id         uuid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    PRIMARY KEY (tenant_id, actor_user_id, operation, key),
    FOREIGN KEY (tenant_id, actor_user_id)  REFERENCES membership (tenant_id, user_id),
    FOREIGN KEY (tenant_id, interaction_id) REFERENCES interaction (tenant_id, id),
    FOREIGN KEY (tenant_id, task_id)        REFERENCES task (tenant_id, id),
    CHECK (status <> 'completed'
           OR (interaction_id IS NOT NULL AND task_id IS NOT NULL AND completed_at IS NOT NULL))
);

-- Consumer-side idempotency: one receipt per (consumer, event) --------------

CREATE TABLE consumer_receipt (
    consumer_name  text NOT NULL CHECK (length(consumer_name) BETWEEN 1 AND 100),
    event_id       uuid NOT NULL,              -- stable event ID from the envelope (Node E)
    tenant_id      uuid NOT NULL REFERENCES tenant(id),
    processed_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer_name, event_id)
);
CREATE INDEX consumer_receipt_tenant_ix ON consumer_receipt (tenant_id, processed_at DESC);
```

---

## 5. Outbox publication contract (database side)

Node E owns the envelope, topics, and Kafka client boundary. The database-side
protocol the publisher must follow — designed so that **no database transaction or
row lock is ever held open across the Kafka network call**:

1. **Claim (short transaction #1).** Select claimable rows and take a short lease:

   ```sql
   BEGIN;
   UPDATE outbox_event
      SET claimed_by = $worker_id,
          lease_expires_at = now() + interval '30 seconds',   -- lease length is worker config
          attempt_count = attempt_count + 1
    WHERE seq IN (
          SELECT seq FROM outbox_event
           WHERE status = 'pending'
             AND (lease_expires_at IS NULL OR lease_expires_at < now())
           ORDER BY seq
           FOR UPDATE SKIP LOCKED
           LIMIT $n)
    RETURNING id, seq, payload;
   COMMIT;   -- lease is now durable; no locks held
   ```

2. **Publish (no transaction).** Send each claimed envelope to Kafka and wait for the
   broker acknowledgement. This happens entirely outside any database transaction.

3. **Acknowledge (short transaction #2).** After broker ack:

   ```sql
   UPDATE outbox_event
      SET status = 'published', published_at = now(),
          claimed_by = NULL, lease_expires_at = NULL
    WHERE id = $id AND status = 'pending';
   ```

   On publish failure, record `last_error` and clear the lease (or let it expire);
   the row stays `pending` and becomes claimable again. Moving a row to `failed`
   after an attempt ceiling is worker policy (Node E).

Properties:

- **At-least-once:** a crash after broker ack but before step 3 leaves the row
  `pending` with an expiring lease; another worker re-claims and re-publishes the same
  envelope. This is intended: consumers are idempotent via receipts (§6).
- **No lost events:** the outbox row committed atomically with the business change
  (§2); a `pending` row can never be silently dropped — it is either published and
  acknowledged, or remains visible as `pending`/`failed` with `last_error`.
- **Ordering caveat:** `seq` is assigned at insert, but concurrent transactions can
  commit out of `seq` order, so a lower-`seq` row may become claimable after a
  higher one has been published. The publisher must not treat `seq` as gap-free or
  strictly commit-ordered; it is a stable *processing* order for rows visible at
  claim time. Strict per-key ordering, if required, is provided by Kafka partitioning
  keys (Node E's contract), not by this table.
- **Worker restart:** killing the worker mid-flight loses nothing — unacknowledged
  claims expire and are re-claimed (slice acceptance criterion).

---

## 6. Consumer processing receipts (consumer-side idempotency)

The follow-up Task is created **synchronously in the HTTP transaction** (§2). The
Kafka consumer never creates tasks. Its side effects are its own (e.g. reminder or
processing records), and its duplicate-delivery obligation is to not repeat *those*
side effects.

Mechanism — the `consumer_receipt` table (DDL in §4), keyed by
`(consumer_name, event_id)` and carrying `tenant_id`:

```
BEGIN;
INSERT INTO consumer_receipt (consumer_name, event_id, tenant_id)
VALUES ($consumer, $event_id, $tenant)
ON CONFLICT (consumer_name, event_id) DO NOTHING;
-- 0 rows inserted → duplicate delivery: skip all side effects, ack the message.
-- 1 row inserted  → first delivery: perform this consumer's side effects
--                   in this same transaction, then commit, then ack.
COMMIT;
```

Because the receipt and the consumer's side effects commit atomically, a duplicate
Kafka delivery (redelivery, rebalance, worker restart) finds the receipt and performs
nothing. `event_id` is the stable event identifier from Node E's envelope; each
distinct consumer uses its own `consumer_name`, so adding consumers later requires no
schema change.

---

## 7. Inspectable end-to-end state: pending → published → processed

The three inspectable states required by the slice are **derived** from two sources —
outbox publication state plus existence of a consumer receipt:

| Inspectable state | Derivation |
|---|---|
| **pending** | `outbox_event.status = 'pending'` (event staged, not yet acknowledged by Kafka). `claimed_by`/`lease_expires_at` additionally show an in-flight publish attempt. |
| **published** | `outbox_event.status = 'published'` (broker-acknowledged at `published_at`) AND no `consumer_receipt` row exists for the event. |
| **processed** | a `consumer_receipt` row exists for `(consumer_name, event_id)`, with `processed_at` as the processing time. With multiple consumers, "processed" is per-consumer. |

Together with `attempt_count`, `last_error`, `created_at`, `published_at`, and
`processed_at`, the complete path is inspectable end to end. No outbox or receipt row
is deleted in the slice.

---

## 8. Migration conventions for Sprint 0002 (tooling-agnostic)

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

## 9. Acceptance self-check (traceability)

| Requirement | Where satisfied |
|---|---|
| Every tenant-owned row carries `tenant_id` | §1 conventions; every tenant-owned table in §4 has `tenant_id NOT NULL` (membership, company, contact, interaction, task, audit_event, outbox_event, idempotency_key, consumer_receipt). |
| Transaction covers all five writes | §2: interaction insert, contact update, mandatory task insert, audit append, outbox append (plus idempotency reservation) in one `BEGIN…COMMIT`. |
| Duplicate HTTP request, same key → one interaction, one task | §3 primary key `(tenant_id, actor_user_id, operation, key)` + same-transaction result recording; backstop `task_one_per_interaction_uq` in §4. |
| Duplicate Kafka delivery → no duplicate business side effect | §6: consumer never creates tasks; its own side effects are gated by the `consumer_receipt` insert committed atomically with them. |
| No transaction/lock held across the Kafka call | §5: claim lease (short txn) → publish outside any txn → acknowledge (short txn). |
| Worker kill/restart loses no event | §2 atomic staging + §5 lease expiry and re-claim. |
| Audit captures actor, tenant, action, record, time | §4 `audit_event`: `actor_user_id` (membership-validated), `tenant_id`, `action`, `record_type`+`record_id`, `occurred_at`. |
| Actor references are provably tenant members | §1 item 3 and §4: composite FKs to `membership (tenant_id, user_id)` on all `created_by`/`assigned_to`/`actor_user_id` columns. |
| Outbox supports at-least-once + inspectable state | §4 `outbox_event` columns; §5 protocol; §7 pending/published/processed derivation. |
