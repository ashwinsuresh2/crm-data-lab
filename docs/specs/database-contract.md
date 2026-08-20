# Database Contract — First Vertical Slice (Sprint 0001, Node D)

Status: contract document for Sprint 0001, remediation pass 2 (barrier rulings
ratified by the human). Documentation only; the DDL below is **illustrative** and
becomes real numbered migrations in Sprint 0002.
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
   that tenant. The FK proves the membership row *exists*; active-ness **at write
   time** is enforced inside every tenant-owned write transaction by the shared
   `withTenantWrite` recheck (§2, statement zero), which closes the
   revocation/suspension race. Membership rows are never deleted (only revoked), so
   historical references stay valid.
4. **Secondary indexes lead with `tenant_id`** (e.g. `(tenant_id, contact_id,
   occurred_at DESC)`), matching the rule that every query carries a tenant predicate.
5. **Enumerated values** use `text` + `CHECK` constraints, not Postgres `ENUM` types
   (cheaper to evolve with forward-only migrations). `interaction.outcome` is special:
   its values are stable **tokens** validated against the **product-defined closed
   vocabulary owned by Node P's contract**. Chosen enforcement: **API-layer
   validation against Node P's list**, with the database constraining presence and
   length only — so vocabulary evolution is a product-contract change, not a schema
   migration. Tokens are stable even when visible labels change: e.g. token
   `not_interested` keeps its token while its label is now "Not interested now"
   (labels are Node P's; tokens do not change). (If Node P later requires DB-level
   enforcement, a `CHECK` mirroring the token list can be added by forward
   migration.)
6. **Timestamps** are `timestamptz`, UTC, with `created_at DEFAULT now()`.
   `interaction.occurred_at` is assigned server-side at write time in this slice.
   Calendar dates (`task.due_on`, the next-action date) use SQL `date` and are
   interpreted against `tenant.operating_timezone`.
7. **Append-only tables** (`interaction`, `audit_event`): no UPDATE/DELETE statements
   in application code; Sprint 0002 may add a `REVOKE UPDATE, DELETE` on these tables
   from the application role (recommended) — either way the contract is append-only.
8. **Row-level security seam:** the slice enforces isolation via composite FKs +
   mandatory tenant predicates + the in-transaction membership recheck +
   tenant-isolation tests. Postgres RLS remains **later defense-in-depth**, not the
   Sprint-0002 solution (ratified ruling); nothing in this schema blocks enabling it
   later.

---

## 2. The log-interaction transaction boundary

The slice's core behavior is one atomic PostgreSQL transaction. **All of the following
commit together or not at all** (`READ COMMITTED` is sufficient; correctness comes
from constraints and row locks, not isolation level). The next-action Task is
**mandatory**: every successful log-interaction creates exactly one open Task.

**`withTenantWrite` (ratified ruling):** every tenant-owned write in the codebase —
not just log-interaction — runs through one shared helper that executes statement
zero below before any write. `FOR SHARE` is required; `FOR KEY SHARE` is explicitly
**not acceptable**, because revocation/suspension is a *non-key* update (`status`
flip) and `FOR KEY SHARE` would not conflict with it. `FOR SHARE` does conflict with
any `UPDATE` of the locked rows, so an in-flight revocation or suspension serializes
against the write: either the recheck sees the committed flip and aborts, or the flip
waits until this transaction commits.

```
BEGIN;

-- (0) withTenantWrite recheck — statement zero of EVERY tenant-owned write.
SELECT 1
  FROM membership m
  JOIN tenant t ON t.id = m.tenant_id
 WHERE m.tenant_id = $tenant AND m.user_id = $actor
   AND m.status = 'active' AND t.status = 'active'
   FOR SHARE OF m, t;
-- no row returned → ROLLBACK immediately; no writes occur.

-- (1) Idempotency reservation — same transaction, see §3.
INSERT INTO idempotency_key (tenant_id, actor_user_id, operation, key, request_hash, status)
VALUES ($tenant, $actor, 'log-interaction', $key, $hash, 'in_progress')
ON CONFLICT (tenant_id, actor_user_id, operation, key) DO NOTHING;
-- if 0 rows inserted → this is a replay or a concurrent duplicate: see §3 flow.

-- (2) Insert the interaction; occurred_at is server-assigned transaction time.
INSERT INTO interaction (id, tenant_id, contact_id, kind, outcome, notes,
                         occurred_at, created_by)
VALUES (..., now(), $actor);

-- (3) Forward-only update of the contact's last-contacted timestamp.
UPDATE contact
   SET last_contacted_at = GREATEST(COALESCE(last_contacted_at, '-infinity'), $occurred_at),
       updated_at        = now()
 WHERE tenant_id = $tenant AND id = $contact_id;

-- (4) Create the mandatory next-action task (exactly 1; ≤1 enforced by unique index;
--     title generated per Node P's outcome→title rules).
INSERT INTO task (id, tenant_id, contact_id, interaction_id, title, due_on,
                  status, assigned_to, created_by)
VALUES (..., $due_on_date, 'open', $actor, $actor);

-- (5) Append the audit record.
INSERT INTO audit_event (id, tenant_id, actor_user_id, action, record_type,
                         record_id, occurred_at, details)
VALUES (..., $actor, 'interaction.logged', 'interaction', $interaction_id, now(),
        jsonb_build_object('task_id', $task_id, 'outcome', $outcome));

-- (6) Append the outbox event (payload = Node E's JSON envelope; the envelope's
--     event_id MUST equal this row's id).
INSERT INTO outbox_event (id, tenant_id, event_type, aggregate_type, aggregate_id,
                          aggregate_version, payload, status)
VALUES ($event_id, $tenant, 'interaction.logged', 'interaction', $interaction_id,
        1, $envelope_jsonb, 'pending');

-- (7) Record the result on the idempotency row before commit.
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
- Statement zero makes membership revocation and tenant suspension race-free with
  respect to writes: a write that commits is proof the membership and tenant were
  active at commit-serialization time.
- The composite FKs — including the actor FKs to membership — re-enforce tenant
  consistency inside the transaction.
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
| task_id | uuid | Result: the created next-action task. Non-null on every committed `completed` row (the task is mandatory). |
| created_at | timestamptz | |
| completed_at | timestamptz, nullable | |

Primary key: `(tenant_id, actor_user_id, operation, key)`.

**Flow (provably one interaction, one task):**

1. Inside the transaction, `INSERT ... ON CONFLICT (tenant_id, actor_user_id,
   operation, key) DO NOTHING`.
2. **Row inserted** → this transaction owns the key; proceed with writes (2)–(7).
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

**Why the guarantee holds — with the roles stated precisely:** the key row, the
interaction, and the task are created in *one* transaction, and the key is unique per
(tenant, actor, operation). Two requests with the same scoped key cannot both insert
the key row, so at most one can perform the business writes. **The "one interaction"
half of the duplicate-request criterion rests solely on this idempotency-key primary
key.** The partial unique index `task_one_per_interaction_uq` (§4) is a backstop for
the *other* half only: it guarantees at most one task **per interaction**, protecting
against a future HTTP retry path that mishandles the key protocol; it says nothing
about interaction duplication. (The Kafka consumer never creates tasks — §6 — so it
is not a duplication vector for either half.)

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
-- Future grant/revoke endpoints emit membership.granted / membership.revoked audit
-- events in the same transaction; slice fixtures are exempt until an endpoint exists.

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
                 -- stable tokens from Node P's closed vocabulary, validated at API layer
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
                    -- deterministic per outcome token; generation rules owned by Node P
    due_on          date NOT NULL,             -- next-action date, interpreted in tenant.operating_timezone
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
-- Backstop for the task-per-interaction half ONLY (see §3 for what it does not cover):
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
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                       -- INVARIANT (Node E seam): the envelope's event_id MUST equal this id
    seq                bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id          uuid NOT NULL REFERENCES tenant(id),
    event_type         text NOT NULL CHECK (length(event_type) BETWEEN 1 AND 100),
    aggregate_type     text NOT NULL CHECK (length(aggregate_type) BETWEEN 1 AND 100),
    aggregate_id       uuid NOT NULL,
    aggregate_version  bigint NOT NULL DEFAULT 1,
    payload            jsonb NOT NULL,         -- Node E's JSON envelope, schema-validated at write
    status             text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','published','failed')),
    claim_id           uuid,                   -- OWNERSHIP GUARD; fresh uuid on every claim
    claimed_by         text,                   -- observability only; never the ownership guard
    lease_expires_at   timestamptz,            -- lease lapse time; expired lease => reclaimable
    attempt_count      integer NOT NULL DEFAULT 0,
    last_error         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    published_at       timestamptz,
    UNIQUE (tenant_id, id),
    CHECK ((status = 'published') = (published_at IS NOT NULL))
);
CREATE UNIQUE INDEX outbox_event_seq_uq ON outbox_event (seq);
CREATE INDEX outbox_event_pending_ix   ON outbox_event (seq) WHERE status = 'pending';
CREATE INDEX outbox_event_aggregate_ix ON outbox_event (tenant_id, aggregate_type, aggregate_id);

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
    consumer_name    text NOT NULL CHECK (length(consumer_name) BETWEEN 1 AND 100),
    event_id         uuid NOT NULL,            -- equals outbox_event.id (== envelope event_id)
    tenant_id        uuid NOT NULL REFERENCES tenant(id),
    status           text NOT NULL DEFAULT 'processing'
                     CHECK (status IN ('processing','processed','failed')),
    attempt_count    integer NOT NULL DEFAULT 1,
    first_seen_at    timestamptz NOT NULL DEFAULT now(),
    last_attempt_at  timestamptz NOT NULL DEFAULT now(),
    processed_at     timestamptz,
    last_error       text,
    PRIMARY KEY (consumer_name, event_id),
    FOREIGN KEY (tenant_id, event_id) REFERENCES outbox_event (tenant_id, id),
                     -- closes the unvalidated-tenant receipt hole: a receipt cannot
                     -- claim a tenant other than the event's own
    CHECK ((status = 'processed') = (processed_at IS NOT NULL))
);
CREATE INDEX consumer_receipt_tenant_ix ON consumer_receipt (tenant_id, last_attempt_at DESC);
```

---

## 5. Outbox publication contract (database side)

Node E owns the envelope, topics, and Kafka client boundary. Envelope seam pinned
here (ratified): **the envelope's `event_id` MUST equal `outbox_event.id`** — Node E's
envelope schema must carry that id, unmodified, so receipts and joins line up.

The database-side protocol — designed so that **no database transaction or row lock
is ever held open across the Kafka network call**, with `claim_id` as the sole
ownership guard:

1. **Claim (short transaction #1).** Select claimable rows and take a short lease.
   A fresh `claim_id` is generated on **every** claim attempt; when an expired lease
   is re-claimed, overwriting `claim_id` **is** the revocation of the prior claim.

   ```sql
   BEGIN;
   UPDATE outbox_event
      SET claim_id = gen_random_uuid(),                     -- fresh on every claim
          claimed_by = $worker_id,                          -- observability only
          lease_expires_at = now() + interval '30 seconds', -- lease length is worker config
          attempt_count = attempt_count + 1
    WHERE seq IN (
          SELECT seq FROM outbox_event
           WHERE status = 'pending'
             AND (lease_expires_at IS NULL OR lease_expires_at < now())
           ORDER BY seq
           FOR UPDATE SKIP LOCKED
           LIMIT $n)
    RETURNING id, seq, payload, claim_id;
   COMMIT;   -- lease is now durable; no locks held
   ```

2. **Publish (no transaction).** Send each claimed envelope to Kafka and wait for the
   broker acknowledgement. This happens entirely outside any database transaction.

3. **Acknowledge / record failure (short transaction #2), guarded by `claim_id`.**
   Every acknowledgment, publish-failure update, and terminal-failure transition
   carries the guard:

   ```sql
   -- success:
   UPDATE outbox_event
      SET status = 'published', published_at = now(),
          claim_id = NULL, claimed_by = NULL, lease_expires_at = NULL
    WHERE id = $event_id AND claim_id = $claim_id AND status = 'pending';

   -- publish failure (row stays pending, becomes claimable again):
   UPDATE outbox_event
      SET last_error = $error, claim_id = NULL, claimed_by = NULL, lease_expires_at = NULL
    WHERE id = $event_id AND claim_id = $claim_id AND status = 'pending';

   -- terminal failure (attempt ceiling is worker policy, Node E):
   UPDATE outbox_event
      SET status = 'failed', last_error = $error,
          claim_id = NULL, claimed_by = NULL, lease_expires_at = NULL
    WHERE id = $event_id AND claim_id = $claim_id AND status = 'pending';
   ```

   **Zero rows updated means the lease was lost** (another worker re-claimed after
   lease expiry, overwriting `claim_id`, or the row already left `pending`). The
   worker must then **stop modifying that row entirely** — no retry of the update,
   no fallback write; ownership now belongs to the current `claim_id` holder.
   `claimed_by` is never used in any `WHERE` clause; it exists for observability
   only.

Properties:

- **At-least-once:** a crash after broker ack but before step 3 leaves the row
  `pending` with an expiring lease; another worker re-claims (new `claim_id`) and
  re-publishes the same envelope. This is intended: consumers are idempotent via
  receipts (§6).
- **No lost events:** the outbox row committed atomically with the business change
  (§2); a `pending` row can never be silently dropped — it is either published and
  acknowledged, or remains visible as `pending`/`failed` with `last_error`.
- **No zombie writers:** the `claim_id` guard means a worker that stalls past its
  lease (GC pause, network partition) cannot clobber state written by the worker
  that re-claimed the row.
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

The next-action Task is created **synchronously in the HTTP transaction** (§2). The
Kafka consumer never creates tasks. **In Sprint 0001 the receipt is the consumer's
only asynchronous side effect: the consumer does not create a Task, does not modify
the Contact, does not send a notification, and does not call any external system.**
Its duplicate-delivery obligation is to not repeat *its own* side effects.

Mechanism — the `consumer_receipt` table (DDL in §4), keyed by
`(consumer_name, event_id)` where `event_id` equals `outbox_event.id` (== the
envelope's `event_id`), carrying `tenant_id` with a composite FK
`(tenant_id, event_id) → outbox_event (tenant_id, id)` so a receipt can never claim a
tenant other than the event's own.

**Skip rule (ratified):** a duplicate delivery is skipped **only** when the existing
receipt has `status = 'processed'`. `failed` receipts remain retryable; `processing`
receipts are re-attempted (at-least-once tolerates the overlap, and the guarded
success update below keeps observability consistent).

**Receipt lifecycle across transactions (ratified):**

1. **Attempt start (short transaction A).** Upsert the receipt; this is where
   `first_seen_at`, `last_attempt_at`, and `attempt_count` advance:

   ```sql
   BEGIN;
   INSERT INTO consumer_receipt
          (consumer_name, event_id, tenant_id, status, attempt_count,
           first_seen_at, last_attempt_at)
   VALUES ($consumer, $event_id, $tenant, 'processing', 1, now(), now())
   ON CONFLICT (consumer_name, event_id) DO UPDATE
      SET status = 'processing',
          attempt_count   = consumer_receipt.attempt_count + 1,
          last_attempt_at = now()
    WHERE consumer_receipt.status <> 'processed'
   RETURNING status;
   COMMIT;
   -- 0 rows returned → existing receipt is 'processed': duplicate delivery.
   --                   Skip all side effects and ack the message.
   -- 1 row returned  → proceed to the work transaction.
   ```

2. **Success (transaction B).** The consumer performs its database side effects (in
   Sprint 0001: none beyond the receipt itself) and, **atomically with them in the
   same transaction**, marks the receipt processed:

   ```sql
   BEGIN;
   -- ... this consumer's transactional (PostgreSQL) side effects, if any ...
   UPDATE consumer_receipt
      SET status = 'processed', processed_at = now()
    WHERE consumer_name = $consumer AND event_id = $event_id
      AND status = 'processing';
   -- 0 rows updated → a concurrent attempt already processed it: ROLLBACK
   --                  (side effects must not commit twice), then ack.
   COMMIT;
   ```

3. **Failure (transaction C, post-rollback, BEST-EFFORT).** If transaction B fails,
   roll it back, then in a separate short transaction record the failure:

   ```sql
   UPDATE consumer_receipt
      SET status = 'failed', last_error = $error
    WHERE consumer_name = $consumer AND event_id = $event_id
      AND status = 'processing';
   ```

   This step is explicitly **best-effort**: a crash between the rollback and this
   update loses that attempt's failure record (the receipt remains `processing` and
   the next delivery re-attempts via step 1). **Success observability remains
   exact** — `processed` is only ever written atomically with the side effects it
   attests to, and `CHECK ((status = 'processed') = (processed_at IS NOT NULL))`
   holds by construction.

**Scope of the atomicity claim (ratified finding):** "receipt atomic with side
effects" holds **only** for transactional PostgreSQL side effects, which are the only
consumer side effects in Sprint 0001. Any future *external* effect (email, HTTP call,
push notification) cannot join the database transaction; it reverts to at-least-once
delivery of that effect and requires its own idempotency/outbox pattern **plus a
decision record** before introduction.

---

## 7. Inspectable end-to-end state, linkage, and joins

### 7.1 Four operator-facing states with strict precedence

The states are **derived** from outbox publication state plus the consumer receipt,
and are **mutually exclusive by construction** because they are evaluated in this
exact precedence order (first match wins):

| Precedence | State | Condition | Extra fields exposed |
|---|---|---|---|
| 1 | **processed** | the required consumer's receipt has `status = 'processed'` | `processed_at` |
| 2 | **failed** | `outbox_event.status = 'failed'` **OR** the receipt has `status = 'failed'` | `failure_stage` = `publication` (with `outbox_event.last_error`) or `consumer` (with `consumer_receipt.last_error`); if both, `publication` is reported first |
| 3 | **published** | `outbox_event.status = 'published'` (broker acknowledged at `published_at`) and neither rule above matched | `published_at`; receipt `status = 'processing'` visible as attempt detail |
| 4 | **pending** | otherwise — **including a row under an active publication lease** | `claimed_by`, `lease_expires_at`, `attempt_count`, `last_error` |

Honest gloss for **pending** (ratified finding): *not yet confirmed published; the
event may already be in the event stream* — the crash window after broker ack but
before the acknowledge transaction (§5) means "pending" cannot promise the event has
not been seen. At-least-once consumers make this safe.

### 7.2 Linkage: Interaction → Outbox event → Consumer receipt

The linkage columns (`event_type`, `aggregate_type`, `aggregate_id`,
`aggregate_version`) plus the pinned invariant *envelope `event_id` =
`outbox_event.id`* make the full asynchronous path queryable with ordinary SQL joins.
For `interaction.logged`: `aggregate_type = 'interaction'`,
`aggregate_id = interaction.id`, `aggregate_version = 1`.

```sql
SELECT i.id                AS interaction_id,
       o.id                AS event_id,          -- == envelope event_id
       o.event_type,
       o.status            AS publication_status,
       o.published_at,
       r.status            AS consumer_status,
       r.attempt_count     AS consumer_attempts,
       r.processed_at
  FROM interaction i
  JOIN outbox_event o
    ON o.tenant_id      = i.tenant_id
   AND o.aggregate_type = 'interaction'
   AND o.aggregate_id   = i.id
  LEFT JOIN consumer_receipt r
    ON r.tenant_id = o.tenant_id
   AND r.event_id  = o.id
   AND r.consumer_name = $consumer
 WHERE i.tenant_id = $tenant
   AND i.id = $interaction_id;
```

Together with `attempt_count`, `last_error`, `created_at`, `published_at`,
`first_seen_at`, `last_attempt_at`, and `processed_at`, the complete path is
inspectable end to end. No outbox or receipt row is deleted in the slice.

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
| Transaction covers all five writes | §2: interaction insert, contact update, mandatory task insert, audit append, outbox append (plus recheck and idempotency reservation) in one `BEGIN…COMMIT`. |
| Membership revocation / tenant suspension cannot race a write | §2 statement zero: `withTenantWrite` `FOR SHARE` recheck on membership and tenant rows (`FOR KEY SHARE` explicitly rejected). |
| Duplicate HTTP request, same key → one interaction, one task | §3: the "one interaction" half rests solely on the primary key `(tenant_id, actor_user_id, operation, key)` + same-transaction result recording; the "one task per interaction" half is additionally backstopped by `task_one_per_interaction_uq` (§4). |
| Duplicate Kafka delivery → no duplicate business side effect | §6: consumer never creates tasks; its only Sprint 0001 side effect is the receipt; duplicates skipped only when receipt `status = 'processed'`, with `failed` retryable. |
| Receipt lifecycle inspectable and correct | §6: attempt-start upsert (own txn, advances `attempt_count`/`last_attempt_at`), success update atomic with side effects, best-effort failure recording; `CHECK ((status='processed') = (processed_at IS NOT NULL))` in §4. |
| Receipt cannot mis-claim a tenant; event identity pinned | §4 `consumer_receipt` composite FK `(tenant_id, event_id) → outbox_event (tenant_id, id)`; §5 invariant: envelope `event_id` = `outbox_event.id`. |
| No transaction/lock held across the Kafka call | §5: claim lease (short txn) → publish outside any txn → acknowledge (short txn). |
| Lease ownership cannot be clobbered by a stale worker | §5: fresh `claim_id` per claim; every lease-holder update guarded by `WHERE id = $event_id AND claim_id = $claim_id AND status = 'pending'`; zero rows → worker stops modifying the row; `claimed_by` observability only. |
| Worker kill/restart loses no event | §2 atomic staging + §5 lease expiry and re-claim. |
| Four mutually exclusive operator states | §7.1: processed → failed (with `failure_stage`) → published → pending, in strict precedence; pending honestly glossed as "not yet confirmed published; may already be in the stream". |
| Interaction → OutboxEvent → ConsumerReceipt queryable by plain SQL | §7.2 join path over `(tenant_id, aggregate_type, aggregate_id)` and `(tenant_id, event_id)`; linkage columns in §4. |
| Audit captures actor, tenant, action, record, time | §4 `audit_event`: `actor_user_id` (membership-validated), `tenant_id`, `action`, `record_type`+`record_id`, `occurred_at`. Worker processing records are explicitly audit-exempt (domain model §2.8). |
| Actor references are provably tenant members | §1 item 3 and §4: composite FKs to `membership (tenant_id, user_id)` on all `created_by`/`assigned_to`/`actor_user_id` columns, plus the §2 in-transaction recheck for active-ness. |
| Outbox supports at-least-once + inspectable state | §4 `outbox_event` columns; §5 protocol; §7 derivation and joins. |
