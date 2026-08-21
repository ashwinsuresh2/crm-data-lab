# Event Contract — First Vertical Slice (Sprint 0001, Node E)

Status: contract document for Sprint 0001, Wave 2. Documentation and JSON Schema
files only; no application code, no Kafka topics created, no infrastructure
touched in this sprint. Implementation lands in Sprint 0002.

Frozen upstream inputs (immutable; conflicts route to the lead):
`docs/specs/WAVE1_FREEZE.md`, `docs/specs/database-contract.md` (D),
`docs/specs/domain-model.md` (D), `docs/specs/product-behavior.md` (P),
`docs/specs/local-topology.md` (I).

Frozen decisions honored here: events are **JSON validated against JSON Schema
files in the repository — no schema registry**; the envelope carries **exactly
twelve fields** (Section 3); the envelope's `event_id` **MUST equal
`outbox_event.id`** (D §5, ratified).

Machine-readable schemas owned by this contract:

- `docs/specs/schemas/event-envelope.v1.schema.json`
- `docs/specs/schemas/interaction-logged.v1.schema.json`

---

## 1. Scope and ownership

This contract owns:

1. Real topic names and the topic naming convention (I §7/§8 marked its names
   illustrative and deferred them here).
2. The event envelope (wire format) and its JSON Schema.
3. The `interaction.logged` payload and its JSON Schema.
4. The partition key and the ordering guarantees of the stream.
5. Producer-side and consumer-side validation obligations.
6. The retry and dead-letter policy for both failure stages (publication and
   consumption) — D §5 ("attempt ceiling is worker policy, Node E") and D §6
   point here.
7. The `last_error` hygiene rules (Wave-1 **Obligation 2**, Section 9).

This contract does **not** own: the outbox row shape, claim/ack protocol, or
receipt lifecycle (D §4–§6 — referenced, never redefined here); the four
operator-facing states (P §6.4 / D §7.1 — referenced); the inspection endpoint
(Node A, Obligation 3); any UI.

The Kafka endpoint stays behind configuration: clients construct their broker
list solely from the shared config module's derived `KAFKA_BROKERS` value
(I §9). No topic name, broker address, or consumer group is hard-coded outside
the constants this contract names.

---

## 2. Topics

### 2.1 Naming convention

```
crm.<stream>.v<major>
```

- `crm` — the product namespace; keeps this project's topics unmistakably
  scoped on a shared local broker.
- `<stream>` — a **domain-oriented** stream name describing what the events
  are about. The wire contract must not encode the transport or staging
  mechanism: `crm.outbox.v1`, `crm.cdc.v1`, and similar mechanism-named topics
  are forbidden. Consumers subscribe to domain facts, not to our outbox
  implementation.
- `v<major>` — the topic's major version. It is bumped only for incompatible
  wire changes: an envelope-shape change that fails old validators, a partition
  rekeying, or a serialization change. Payload evolution inside the envelope is
  versioned by `schema_version` (Section 3.3), **not** by the topic name.

### 2.2 The slice topic (real name, normative)

| Property | Value |
|---|---|
| Topic | `crm.events.v1` |
| Carries | All CRM domain events in the slice; in Sprint 0001 the only event type is `interaction.logged` |
| Partitions | `1` in the local slice (created explicitly by the Sprint-0002 idempotent init step, I §7; broker auto-create stays disabled) |
| Cleanup policy | `delete`, `retention.ms = 604800000` (7 days) |
| Envelope | `event-envelope.v1` (Section 3) |

One shared domain-event stream (rather than a topic per aggregate) is the
"tiny fleet" choice: one event type exists, the envelope's `event_type`
dispatches, and per-tenant ordering across future event types comes free from
the partition key (Section 4). Splitting into per-aggregate topics later is a
new-topic addition, not a breaking change.

Bounded retention is safe **because Kafka is not the system of record**:
PostgreSQL's outbox holds every event durably and forever in the slice (D §7),
and the replay procedure (Section 8.3) can republish every surviving outbox
event as **new** Kafka records carrying the same logical envelope values — it
does not resurrect the original records, their offsets, or their original
interleaving. The loss-of-nothing acceptance criteria rest on the outbox,
never on Kafka retention.

I §8's example commands happen to use `crm.events.v1` and `crm-worker`; this
section is what makes those names real. That is a deliberate convergence, not
an inheritance — the names are owned here.

### 2.3 Consumer group and consumer name (real names, normative)

| Property | Value |
|---|---|
| Kafka consumer group (`group.id`) | `crm-worker` |
| Receipt `consumer_name` (D §4/§6) | `crm-worker` |

The receipt `consumer_name` equals the consumer group id so that the
`(consumer_name, event_id)` receipt key, the canonical offset-reset redelivery
command (I §8), and the operator's mental model all name the same thing. A
future second consumer gets a new group id and a new `consumer_name`, and by
D §6 its receipts are independent.

---

## 3. The event envelope (`event-envelope.v1`)

Schema: `docs/specs/schemas/event-envelope.v1.schema.json`
(JSON Schema draft 2020-12, declared via `$schema`).

The envelope is the complete Kafka message value, serialized as UTF-8 JSON.
It has **exactly these twelve fields** (frozen decision) — all present on
every message, `additionalProperties: false`:

| # | Field | Type / format | Semantics |
|---|---|---|---|
| 1 | `event_id` | uuid | Globally unique event identity. **MUST equal `outbox_event.id`** — D §5's pinned invariant. This is what makes consumer receipts (`consumer_receipt.event_id`) and the end-to-end joins (D §7.2) line up, and what makes replay dedupe correctly. |
| 2 | `tenant_id` | uuid | Owning tenant. MUST equal `outbox_event.tenant_id`. Also the partition key (Section 4). |
| 3 | `event_type` | string, `<aggregate>.<past-tense-verb>` | e.g. `interaction.logged`. MUST equal `outbox_event.event_type`. Dispatch key for payload validation. |
| 4 | `aggregate_type` | string | Logical domain object, e.g. `interaction`. MUST equal `outbox_event.aggregate_type`. |
| 5 | `aggregate_id` | uuid | The domain row's id, e.g. `interaction.id`. MUST equal `outbox_event.aggregate_id`. |
| 6 | `aggregate_version` | integer ≥ 1 | Version of the aggregate at emission; `1` for append-only interactions in the slice. MUST equal `outbox_event.aggregate_version`. |
| 7 | `occurred_at` | RFC 3339 date-time (UTC) | Business time of the fact: for `interaction.logged`, the server-assigned `interaction.occurred_at` (transaction time, D §2). A business timestamp, **not** a delivery-order guarantee (Section 5). |
| 8 | `actor_id` | uuid | The acting user's `user_id` — provably a member of `tenant_id` via D's composite actor FKs and the `withTenantWrite` recheck. |
| 9 | `schema_version` | integer ≥ 1 | Major version of the **payload** schema for this `event_type` (Section 3.3). `1` in the slice. |
| 10 | `correlation_id` | uuid | Identifies the causal chain. Minted by the API once per HTTP request; every event staged by that request carries it. Lets logs, audit rows, and events for one submission be tied together. |
| 11 | `causation_id` | uuid or null | `event_id` of the direct causal predecessor **event**, or `null` when the event originates directly from a user action rather than from another event. In Sprint 0001 it is always `null` (no event-driven producers exist). The field is always present. |
| 12 | `payload` | object | The event-type-specific body, validated against the schema selected by (`event_type`, `schema_version`). |

The envelope duplicates the outbox linkage columns by design: the wire message
is self-contained, and D §4 mirrors those values into columns for SQL-level
querying. The producer obligation that they be **equal** is normative
(Section 6.2).

**Data minimization (normative):** the interaction's free-text notes are
**intentionally excluded** from the `interaction.logged` payload, and
sensitive free-text CRM content is excluded from every event payload in this
slice. The event stream carries identifiers, stable tokens, dates, and
timestamps only; timeline text is read from PostgreSQL, which is
authoritative. (Stated here as contract prose, not only in the payload
schema's description.)

### 3.1 Strictness

`additionalProperties: false` at the envelope level, on both producer and
consumer. With no registry and both ends in one repository, silent field drift
is a bug we want loud, not tolerated. Adding an envelope field is an
incompatible wire change → new envelope schema and topic major version
(Section 2.1).

### 3.2 Envelope versioning

The envelope schema version is bound to the topic major version:
`crm.events.v1` carries `event-envelope.v1` messages, exclusively. There is no
in-band envelope-version field; `schema_version` (field 9) versions the
payload only.

### 3.3 `schema_version` semantics

- Integer, starting at 1, scoped **per `event_type`**.
- Names the payload schema file: (`interaction.logged`, `1`) →
  `interaction-logged.v1.schema.json`.
- Incremented for any change that can fail an existing validator of that
  payload (removed/renamed fields, type changes, narrowed enums, new required
  fields — and, because payload schemas are also strict, added fields).
- Consumers are deployed to understand a new (`event_type`, `schema_version`)
  **before** any producer emits it (Section 7.2 defines what happens if this
  rule is violated).

### 3.4 Validator requirements (normative)

- Producer-side and consumer-side validation (Sections 6.1, 7.1) MUST use a
  JSON Schema **draft 2020-12** validator with **format assertion enabled** —
  e.g. Ajv in strict mode with `ajv-formats` in assertion mode, or an
  equivalent. Draft 2020-12 treats `format` as annotation by default;
  format-as-annotation does **not** satisfy this contract.
- Consequently each of these MUST fail envelope validation:
  `event_id = "banana"`, `tenant_id = "banana"`, `actor_id = "banana"`,
  `occurred_at = "not-a-date"` — and the analogous payload fields
  (`interaction_id`, `tenant_id`, `contact_id`, `company_id`, `task_id`,
  `actor_user_id`, `occurred_at`, `next_action_date`) fail payload validation
  under the same rule.
- Explicit negative fixtures for the UUID and date-time (and date) formats are
  part of the required test set (Section 10).

---

## 4. Partition key

**The message key is `tenant_id`** (the UUID's canonical lowercase string
form, UTF-8 encoded).

What this guarantees:

- All events of one tenant land on one partition, so every consumer in the
  group observes a tenant's events in the order the publisher produced them
  (Kafka's per-partition ordering).
- Because every aggregate belongs to exactly one tenant, all events for one
  aggregate are also on one partition, in produced order.
- Tenant affinity: a tenant's stream is never interleaved across consumers of
  the same group.

What this deliberately does **not** guarantee:

- **No cross-tenant ordering.** Events of different tenants may be observed in
  any relative order.
- **No commit-order guarantee.** The publisher claims outbox rows in `seq`
  order, but D §5 is explicit that `seq` is not gap-free or strictly
  commit-ordered under concurrency; produced order is the claim-time
  processing order, not transaction commit order.
- **No `occurred_at` order guarantee.** Redelivery, retries, and replay can
  interleave; consumers needing business-time order must sort by
  `occurred_at` (or read PostgreSQL, which is authoritative).
- **No stability across a partition-count change.** Increasing partitions
  remaps keys; per-tenant ordering then holds only from the change onward. If
  strict rekeying is ever required, the clean path is a new topic major
  version (Section 2.1), not an in-place repartition.

The slice runs one partition, so these guarantees are trivially strong today;
the key is mandated now so growing partition count later changes nothing in
the contract.

---

## 5. Ordering summary (normative)

1. Per-partition (hence per-tenant, hence per-aggregate) **delivery order =
   produced order**. Nothing more.
2. `outbox_event.seq` is **internal publisher-coordination metadata** (D §4,
   D §7.1 confidentiality rule): not gap-free, not commit-ordered, never
   exposed in the envelope, in any API response, or to consumers. Nothing in
   this contract lets a consumer or tenant observe `seq`, and no consumer may
   infer completeness ("no gaps") or global order from anything on the wire.
3. At-least-once delivery means duplicates are normal (D §5); consumers handle
   them via receipts (Section 7.3), never by assuming ordering.

---

## 6. Producer obligations

The "producer" is the outbox publisher inside the background worker. It is the
**only** writer to `crm.events.v1`.

### 6.1 Where the envelope is built and validated

- The envelope is constructed by the API **inside the log-interaction
  transaction** and stored as `outbox_event.payload` (D §2 step 6, D §4:
  "schema-validated at write"). Validation against `event-envelope.v1` **and**
  the payload schema selected by (`event_type`, `schema_version`) happens
  there, before commit — an invalid envelope can never be staged.
- The publisher validates the envelope **again** immediately before sending
  (defense in depth against schema drift between staging and publish time).
  Publisher-side validation failure is deterministic and is handled as a
  non-retryable publication failure (Section 8.1).

### 6.2 Identity and linkage invariants (checked, not assumed)

Before publish, the publisher asserts, and tests must prove:

- `envelope.event_id == outbox_event.id` — **the pinned invariant (D §5)**.
- `envelope.tenant_id == outbox_event.tenant_id`,
  `envelope.event_type == outbox_event.event_type`,
  `envelope.aggregate_type == outbox_event.aggregate_type`,
  `envelope.aggregate_id == outbox_event.aggregate_id`,
  `envelope.aggregate_version == outbox_event.aggregate_version`.
- Envelope ↔ payload equalities for `interaction.logged`:
  `payload.interaction_id == envelope.aggregate_id`,
  `payload.tenant_id == envelope.tenant_id`,
  `payload.actor_user_id == envelope.actor_id`,
  `payload.occurred_at == envelope.occurred_at`.

Linkage mapping for the slice event, normative:

| Envelope field | Value for `interaction.logged` |
|---|---|
| `event_type` | `interaction.logged` |
| `aggregate_type` | `interaction` |
| `aggregate_id` | the `interaction.id` created in the same transaction |
| `aggregate_version` | `1` |

Any mismatch — in either checklist above — is a producer bug: recorded with
code `EVENT_LINKAGE_MISMATCH` (Section 9) and treated as a non-retryable
publication failure (Section 8.1), never "fixed up" in flight — the outbox row
is the audit trail of what was staged.

### 6.3 Publish mechanics

- Message: key = `tenant_id` (Section 4), value = the envelope JSON, topic =
  `crm.events.v1`.
- Producer settings: `acks=all` and the client's idempotent-producer mode
  enabled. These reduce broker-side duplication; they do **not** change the
  end-to-end model, which remains at-least-once with receipt-based dedupe.
- The claim → publish → acknowledge protocol, the `claim_id` ownership guard,
  and the zero-rows-means-lease-lost rule are D §5's, verbatim and unmodified.
  The publisher waits for the broker acknowledgement before running D's
  success update; broker-ack-then-crash leaves the row `pending` and is
  re-published (intended; receipts dedupe).

---

## 7. Consumer obligations

The "consumer" is the worker's `crm-worker` group member. Per P §6.5 / D §6,
its **only** Sprint-0001 side effect is the processing receipt. It performs no
external side effects — and none may be added in any shadow-engine comparison
mode either (charter rule).

### 7.1 Validation on read

For every delivered message, in order:

1. Parse the value as UTF-8 JSON.
2. Validate against `event-envelope.v1` (strict).
3. Dispatch on (`event_type`, `schema_version`) to the payload schema —
   in the slice, (`interaction.logged`, 1) →
   `interaction-logged.v1.schema.json` — and validate `payload` (strict).
4. Only then run the receipt lifecycle (Section 7.3).

### 7.2 Behavior on invalid input (feeds the dead-letter policy, Section 8.2)

Validation failures are **deterministic**: redelivering the same bytes cannot
succeed, so they are never retried in-process.

- **Tier 1 — attributable invalid event.** The message parses, and its
  `event_id`/`tenant_id` resolve to an existing outbox row (the receipt's
  composite FK can hold). This covers payload-schema failures, unknown
  `event_type`, and unknown `schema_version`. The consumer records a `failed`
  receipt via the **atomic create-or-update park write (Section 8.2.1)** —
  which creates the receipt even when no receipt row exists yet (a zero-row
  `UPDATE` against a nonexistent receipt is not a valid mechanism) and
  preserves the skip-on-processed rule — with error code
  `EVENT_SCHEMA_INVALID`, `EVENT_TYPE_UNKNOWN`, or
  `EVENT_SCHEMA_VERSION_UNKNOWN` (Section 9). The Kafka offset is committed
  **only after** the failed receipt is durably recorded — or after the upsert
  reports the receipt is already `processed`, in which case this is a
  duplicate delivery (e.g. redelivered after a validator change) and is
  skip-and-acked with the receipt untouched. The event surfaces as state
  **failed** / `failure_stage = consumer` (P §6.4, D §7.1). Unknown
  types/versions park visibly rather than skip silently because this
  consumer's contract is a receipt for *every* event; the deploy-consumers-
  first rule (Section 3.3) makes this an operational error worth seeing.
- **Tier 2 — unattributable message.** The value does not parse, fails
  envelope validation, or names an (`event_id`, `tenant_id`) with no matching
  outbox row (the receipt insert would violate its FK). No receipt is
  possible. The consumer writes a sanitized structured line to the protected
  process log — topic, partition, offset (Kafka coordinates are permitted
  **only** in this protected log — Section 9 rule 2), error code, byte length;
  **never the raw bytes** (Section 9) — commits the offset, and continues. In
  the slice
  the only writer is our own publisher, so tier 2 indicates a serious bug or a
  foreign producer; detection is the log line plus the monitoring signal that
  an outbox row sits `published` with no receipt past the 30-second bound
  (P §4 step 6).

### 7.3 Idempotency (reference — D §6 is the mechanism; nothing here conflicts)

Consumer idempotency is **entirely** D §6's receipt lifecycle:

- Attempt-start upsert (D §6 step 1): zero rows returned ⇒ the existing
  receipt is `processed` ⇒ **duplicate delivery: skip all side effects and
  acknowledge**. That is the only skip condition — `failed` receipts remain
  retryable, `processing` receipts are re-attempted.
- Success finalization atomic with side effects (D §6 step 2), including the
  ratified **zero-row re-read finalization rule**: zero rows updated is never
  proof of prior success; re-read the receipt in a fresh transaction and act
  on what it actually says.
- Best-effort failure recording (D §6 step 3).

This contract adds only the **offset-commit rule** binding Kafka to that
lifecycle: the consumer commits an offset **only after** the receipt outcome
for that message is decided — `processed` (fresh or duplicate-skip) or parked
per Section 7.2/8.2. A crash before the commit redelivers the message;
receipts make redelivery harmless. Auto-commit is disabled.

**Park is not "processed" (normative clarification):** committing an offset on
park is a transport-level statement only — "this group will not automatically
redeliver this record" — and is **not** the "acknowledge as successfully
processed" that D §6's zero-row re-read finalization rule forbids. The durable
truth about processing is always the receipt: a parked event's receipt says
`failed`, the four-state surface shows **failed**, and the event remains
re-drivable (Section 8.2). Nothing here weakens D §6's rule that zero rows
updated is never proof of successful prior processing.

### 7.4 Replayability and observability

Every consumer must be replayable (safe under Section 8.3 replay and I §8
offset reset, guaranteed by receipts), observable (receipt rows carry
`attempt_count`, `first_seen_at`, `last_attempt_at`, `processed_at`,
`last_error`; the four states derive per D §7.1), and idempotent (above).
These are standing requirements for every future consumer on this topic, not
just the slice worker.

---

## 8. Retry and dead-letter policy (owned here)

Design constraints: no new infrastructure; every event already has a durable,
never-deleted record in PostgreSQL (the outbox row) plus, once seen, a receipt.

**Decision: no dead-letter topic.** A dead letter is a **terminal `failed`
state in PostgreSQL** with full operator visibility. Justification: a DLQ
topic would be a second durable copy of data the authoritative store already
holds, with worse queryability, its own retention problem, and bespoke
re-drive machinery — while the four-state inspection surface (P §6.4, Node A's
endpoint per Obligation 3) already exposes `failed` with `failure_stage` and
`last_error`, and re-drive already exists (I §8 offset reset; Section 8.3
replay; the resurrection procedures below). This is "world-class seams, tiny
fleet": the seam (a parked event is visible, diagnosable, and re-drivable) is
first-class; the extra topic is not needed to achieve it.

### 8.1 Stage (a): publication failures (outbox → Kafka)

Mechanics are D §5's; this section supplies the policy D delegates.

- **Attempt accounting:** `outbox_event.attempt_count` increments on every
  claim (D §5 step 1); the value is contractually available to this policy via
  the claim's `RETURNING` list (human-approved Wave-1 amendment to D §5).
- **Ceiling:** `MAX_PUBLISH_ATTEMPTS = 10` (worker configuration; 10 is the
  contract default).
- **Lease default (AC-5 reconciliation):** D §5 leaves the lease length to
  worker configuration (its illustrative SQL shows 30 s). This contract pins
  the default publication lease to **10 seconds** — deliberately well under
  the 30-second AC-5 bound — so a worker killed mid-claim leaves an orphaned
  lease that expires and is re-claimed quickly enough for re-publish and
  consumption to complete within the bound. The AC-5 clock starts at worker
  restart (P §6.3).
- **Retryable failure** (broker unreachable, timeout, transient send error)
  with `attempt_count < 10`: run D §5's publish-failure update (row stays
  `pending`, claim cleared, sanitized `last_error` recorded). The row becomes
  claimable again; pacing comes from the claim loop below.
- **Backoff:** retry spacing is provided by the publisher's claim loop, not
  per-row state (D's schema has no per-row backoff column, and broker outages
  affect all rows at once): base poll interval 1 s; on any publish failure in
  a batch, the loop backs off exponentially (2×, jittered) to a 30 s cap;
  first success resets it.
- **Terminal failure:** when a publish attempt fails and the claim's returned
  `attempt_count ≥ 10`, run D §5's terminal-failure update →
  `status = 'failed'`, sanitized `last_error`. The event is now **parked
  (dead-lettered) at the publication stage**: state **failed** /
  `failure_stage = publication`.
- **Non-retryable failure** (deterministic: envelope fails Section 6.1
  publisher-side validation, Section 6.2 invariant mismatch, or the broker
  rejects the message as malformed/oversized): terminal-failure update
  **immediately**, ignoring the ceiling — retrying deterministic failures
  wastes the ceiling and delays operator attention.
- **Operator resurrection (documented ops procedure, Sprint 0002):** after
  fixing the cause, an operator script re-opens the row —
  `UPDATE outbox_event SET status='pending', attempt_count=0, claim_id=NULL,
  claimed_by=NULL, lease_expires_at=NULL WHERE id=$event_id AND
  status='failed'` (`last_error` retained until the next attempt overwrites
  it). The publisher then picks it up normally. This is the only path out of
  publication-failed. Resurrection performs exactly this one outbox `UPDATE`:
  no receipt rows are written and no consumer offset is touched.

### 8.2 Stage (b): consumer failures (Kafka → receipt)

Mechanics are D §6's; this section supplies the retry policy D §6 points at.
Every transition below states which receipt/outbox writes occur and when the
Kafka offset commits.

#### 8.2.1 The failed-receipt park write (atomic upsert, normative)

Tier-1 invalid events (Section 7.2) and ceiling parking both require a
`failed` receipt to exist **even when no receipt row exists yet**. A zero-row
`UPDATE` against a nonexistent receipt is **not** a valid mechanism; the park
write is an atomic create-or-update upsert (illustrative SQL, receipt DDL is
D §4's):

```sql
INSERT INTO consumer_receipt
       (consumer_name, event_id, tenant_id, status, attempt_count,
        first_seen_at, last_attempt_at, last_error)
VALUES ($consumer, $event_id, $tenant, 'failed', 1, now(), now(), $safe_error)
ON CONFLICT (consumer_name, event_id) DO UPDATE
   SET status          = 'failed',
       attempt_count   = consumer_receipt.attempt_count + 1,
       last_attempt_at = now(),
       last_error      = EXCLUDED.last_error
 WHERE consumer_receipt.status <> 'processed'
RETURNING status;
-- 1 row  → the failed receipt is durably recorded, carrying tenant_id,
--          consumer_name, event_id, status='failed', attempt_count,
--          first_seen_at, last_attempt_at, processed_at = NULL (so D §4's
--          CHECK holds), and a sanitized last_error. ONLY NOW may the Kafka
--          offset be committed.
-- 0 rows → the existing receipt is 'processed' (e.g. an already-processed
--          event redelivered after a validator change): skip-and-ack — the
--          receipt is untouched and the offset commits as a duplicate-skip.
--          D §6's skip-on-processed rule is preserved exactly.
```

`$safe_error` is a Section 9 sanitized `CODE: summary`. If this upsert itself
fails, the offset is **not** committed; the message will be redelivered and
the park re-attempted (`RECEIPT_WRITE_FAILED` detail in the protected process
log).

#### 8.2.2 Policy

- **Attempt accounting:** `consumer_receipt.attempt_count` increments on every
  attempt-start upsert (D §6 step 1) and every 8.2.1 park write, across
  deliveries and restarts; the value is contractually available via the
  attempt-start operation's `RETURNING` list (human-approved Wave-1 amendment
  to D §6).
- **Ceiling:** `MAX_CONSUME_ATTEMPTS = 10` (worker configuration; contract
  default 10), evaluated against `consumer_receipt.attempt_count`.
- **Retryable failure** (receipt/work transaction fails: PostgreSQL
  unavailable, timeout, transient error) with `attempt_count < 10`: record the
  `failed` receipt best-effort (D §6 step 3), do **not** commit the offset,
  **seek back** to the failed message's offset, and retry through the full
  path (attempt-start upsert included) after an in-process backoff of
  1 s doubling to a 30 s cap. This is the **redelivery-through-the-real-path**
  retry, the same at-least-once condition the canonical offset-reset tooling
  (I §8) exercises in tests.
- **Cross-tenant head-of-line blocking (named, accepted slice-scale risk):**
  seek-back blocks the entire partition, and with the slice's single partition
  that means one tenant's failing event delays **every** tenant's events for
  up to the bounded retry window. This is accepted for the slice (seeded
  internal tenants only, bounded by the ceiling and backoff cap).
  **Pre-external-exposure requirement:** before any external tenant or
  non-local exposure, partition/tenant fairness or bounded blocking must be
  introduced (e.g. multiple partitions keyed by `tenant_id` plus a bounded
  per-message retry budget) — recorded alongside P's pre-exposure
  requirements (the P-AUTH-8 rate-limiting precedent).
- **Parking (dead-letter):** when an attempt fails and `attempt_count ≥ 10`,
  or on any deterministic tier-1 validation failure (Section 7.2, no retries
  at all): run the **8.2.1 park write**; only after it durably records the
  `failed` receipt (sanitized `last_error`, Section 9) is the offset
  committed, and the consumer moves on. The partition unblocks; the event is
  parked as state **failed** / `failure_stage = consumer`, visible with
  `attempt_count`, timestamps, and `last_error` via D §7 / Node A's surface.
  Committing the offset here is transport-level only — not a claim of
  successful processing (Section 7.3's park-is-not-processed clarification).
- **Re-drive of parked events:** a `failed` receipt is **never** permanently
  unprocessable — D §6's ratified skip rule (skip only on `processed`) is
  untouched. The ceiling bounds the *automatic in-process* retry loop only.
  Operator-initiated redelivery — the canonical
  `kafka-consumer-groups.sh --reset-offsets` procedure (I §8) or outbox replay
  (Section 8.3) — always grants the event one fresh attempt per delivery
  (attempt-start upsert runs, `attempt_count` advances); past the ceiling
  there is simply no further automatic seek-back loop, so the event either
  processes or re-parks after that one attempt.
- If both stages have failure evidence, presentation precedence is
  `failure_stage = publication` first (P §6.4's ratified tie-break); neither
  underlying record is erased.

### 8.3 Restart and replay

- **Worker restart loses nothing (AC-5 / P §6.3).** Publisher side: an
  in-flight claim's lease expires and the row is re-claimed with a fresh
  `claim_id` (D §5); the staged event cannot be lost because it committed with
  the business transaction (D §2). Consumer side: offsets are committed only
  per Section 7.3's rule, so a crash redelivers unfinished messages; the
  attempt-start upsert and skip rule make redelivery harmless. No user or
  operator action is required; the 30-second processed bound applies after
  restart.
- **Outbox replay (I §6, Sprint-0002 deliverable).** Precondition, preserved
  from I §6: **replay is valid only when PostgreSQL and its outbox table
  survive** — if the outbox is gone there is nothing to replay from.
  Procedure: re-publish outbox rows to `crm.events.v1` in outbox insertion
  order (internal `seq` order — used as the tool's processing order, never
  exposed on the wire), optionally filtered by tenant and/or time range.
  Outbox replay republishes the **same logical envelope values** — including
  the same `event_id`, `tenant_id`, `event_type`, aggregate identity and
  version (`aggregate_type`, `aggregate_id`, `aggregate_version`),
  `schema_version`, `correlation_id`, `causation_id`, and `payload` — using
  the **current canonical JSON serializer**, with the same partition key
  (`tenant_id`). Because `event_id` is preserved, receipts dedupe exactly
  (`processed` receipts skip-and-ack per D §6) and replay is safe to run
  repeatedly and after partial failures. Replay itself performs **no external
  side effects**; it only writes to Kafka. Side-effect protection lives
  entirely in consumer receipts.
- **Replay identity vs. offset reset (normative distinction).** Kafka offset
  reset (I §8) re-reads the **original** Kafka records at their **existing**
  offsets. Outbox replay creates **new** Kafka records at **new** offsets from
  surviving PostgreSQL outbox state; it cannot reconstruct original Kafka
  offsets, and it cannot reconstruct the original interleaving relative to
  events published later. No byte-identical re-publication is promised —
  identity is the logical envelope values above, anchored on `event_id`, never
  an offset or byte sequence.
- **Canonical duplicate-delivery mechanism (AC-4 / P §6.2).** The
  `kafka-consumer-groups.sh` offset reset (I §8) is canonical for the
  duplicate-event acceptance test because it redelivers identical
  already-published messages through the real consumer path; replay is the
  documented alternative for targeted/filtered re-publish.

---

## 9. `last_error` hygiene — Wave-1 Obligation 2 (normative)

The following requirements are carried verbatim from `WAVE1_FREEZE.md`
Obligation 2 and apply to **both** `outbox_event.last_error` and
`consumer_receipt.last_error`:

- `last_error` is bounded and sanitized.
- It contains an error code and a safe operator-facing summary.
- It must not contain credentials, dev tokens, raw event payloads, email
  bodies, notes, or other sensitive CRM content.
- Detailed exceptions belong in protected process logs.
- This is mandatory before any non-local deployment.

Concrete rules implementing the obligation:

1. **Format:** `CODE: summary` — a stable safe code from the closed list
   below, a colon, and a single-line safe operator-facing summary. Total
   length ≤ 500 characters, truncated with `…` if longer. The summary is
   **constructed from the closed code's template plus safe scalars only**
   (attempt number, broker error class, elapsed milliseconds); it never
   interpolates exception messages, stack traces, SQL text, request bodies,
   envelope payloads, notes, tokens, or connection strings.
2. **Kafka coordinates are protected-log-only:** Kafka topic names, partition
   numbers, and offsets may exist **only** in protected process logs. They are
   never written into `outbox_event.last_error`, `consumer_receipt.last_error`,
   or any tenant-facing response. A partition offset is a global monotone
   counter: exposing it would let one tenant infer other tenants' event volume
   and ordering — the same leak class as `outbox_event.seq` (D §7.1). Node A's
   response-field allowlist is defense in depth; this rule is the source.
3. **Closed code list (extend by contract change only):**
   `BROKER_UNAVAILABLE`, `PUBLISH_TIMEOUT`, `PUBLISH_REJECTED`,
   `EVENT_SCHEMA_INVALID`, `EVENT_LINKAGE_MISMATCH`, `EVENT_TYPE_UNKNOWN`,
   `EVENT_SCHEMA_VERSION_UNKNOWN`, `RECEIPT_WRITE_FAILED`, `CONSUMER_DB_ERROR`,
   `CONSUMER_UNEXPECTED`.
4. **Full diagnostics** (stack traces, driver errors, raw broker responses,
   and Kafka topic/partition/offset coordinates) go to the worker's protected
   process log, keyed by `event_id` and `correlation_id` so operators can
   pivot from the safe summary to the detail. The process log also never
   records token material (consistent with P-AUTH-8's rule for the API log).
5. **Tests:** the failure-path tests (Section 10) assert that `last_error`
   matches `^[A-Z_]+: ` against the closed code list, is ≤ 500 chars, and
   contains none of: the interaction note text, any payload JSON, any seeded
   dev token, any connection string fragment, any Kafka topic name, or any
   partition number or offset digits. This gate is mandatory before any
   non-local deployment.

---

## 10. Acceptance mapping and required tests

| Criterion | Mechanism defined | Test (automated) |
|---|---|---|
| AC-4 / P §6.2 — duplicate delivery invisible | Receipts, skip only on `processed` (D §6, Section 7.3); canonical offset-reset redelivery (Section 8.3) | Process an event to `processed`; reset offsets per I §8; assert exactly one receipt for that `event_id`, receipt still `processed`, and P §4 invariant counts unchanged. |
| AC-5 / P §6.3 — worker restart loses nothing | Lease expiry + re-claim (D §5); offset-commit-after-receipt rule (Section 7.3); at-least-once end to end (Section 8.3) | Stop worker → submit → assert state pending/published, not processed → restart → state `processed` within 30 s; invariant counts unchanged. |
| Publication failure → retry → park | Section 8.1 ceiling 10, claim-loop backoff, terminal `failed`, `failure_stage = publication` | With broker stopped: submit; assert row stays `pending` with rising `attempt_count` and sanitized `last_error`; force ceiling (config = small N in test) → `status='failed'`; assert Section 9 hygiene including **no Kafka topic name and no partition/offset digits** in `last_error`; resurrect per 8.1 with broker up → `processed`. |
| Consumer failure → retry → park → re-drive | Section 8.2 ceiling 10, seek-back retry, 8.2.1 park write, one-attempt-per-redelivery re-drive | Inject receipt-transaction failure; assert `attempt_count` advances, offset not committed below ceiling; at ceiling assert the 8.2.1 upsert recorded receipt `failed` **before** the offset committed, state failed/`failure_stage=consumer`; clear the fault, redeliver per I §8 → `processed` (skip rule untouched). |
| Invalid payload on read | Section 7.2 tier 1: no retry, 8.2.1 park write, park | Publish (test-harness path) a tier-1 invalid message for an event with **no existing receipt row**; assert the 8.2.1 upsert **creates** the `failed` receipt (`attempt_count = 1`, `processed_at` null, sanitized `last_error` = `EVENT_SCHEMA_INVALID: …`) and the offset commits only after it; no retry loop. Then mark an event `processed` and redeliver it under a now-failing validator; assert skip-and-ack: receipt remains `processed` and untouched. |
| Unattributable message | Section 7.2 tier 2: protected log line, offset committed, no receipt | Produce garbage bytes to the topic in a test; assert consumer survives, logs sanitized line (Kafka coordinates in the protected log only), commits offset, and processes the next valid event. |
| Envelope validity + pinned invariant + linkage | Sections 3.4, 6.1–6.2 | Unit tests with the Section 3.4 asserting validator: valid envelope passes `event-envelope.v1`; each missing/extra field fails; **negative format fixtures fail** — `event_id`/`tenant_id`/`actor_id` = `"banana"`, `occurred_at` = `"not-a-date"`, plus the payload analogues (bad uuids, bad `date-time`, bad `date`); `event_id ≠ outbox_event.id` and every Section 6.2 envelope↔outbox and envelope↔payload equality violation is rejected before publish with `EVENT_LINKAGE_MISMATCH`. |
| Replay safety | Section 8.3 | Run replay twice over a processed range; assert receipt count per event stays 1 and no state changes; assert replayed records are new records (new offsets) carrying identical logical envelope values. |

## 11. Self-check against the freeze

- Envelope has exactly the 12 mandated fields, in Section 3, matching the
  frozen list — no additions, no omissions.
- `event_id = outbox_event.id` stated as MUST (Sections 3, 6.2), matching
  D §5's ratified pin.
- Topic names owned and domain-oriented; no outbox/mechanism encoding
  (Section 2); I's illustrative names resolved here.
- Retry/dead-letter defined for both stages with ceilings, backoff, park
  semantics, and re-drive; D §6's skip rule and zero-row re-read rule are
  referenced unmodified and nothing conflicts with them; D §7.1 / P §6.4 four
  states and tie-break referenced unmodified.
- `seq` confidentiality preserved (Section 5); never on the wire. Kafka
  topic/partition/offset coordinates confined to protected process logs
  (Section 9 rule 2) — never in `last_error` or tenant-facing responses.
- Obligation 2 included verbatim with implementing rules (Section 9); format
  validation is normative and asserting (Section 3.4).
- Tier-1 invalid events park via an atomic create-or-update receipt upsert
  (Section 8.2.1) that works with no pre-existing receipt row and preserves
  skip-on-processed; offset commits only after the failed receipt is durable.
- Replay promises logical-envelope-value identity (anchored on `event_id`)
  via the current canonical serializer — never byte, offset, or interleaving
  identity (Section 8.3); the PostgreSQL-survival precondition is preserved.
- Publication lease default pinned at 10 s, under the 30-second AC-5 bound
  (Section 8.1); cross-tenant head-of-line blocking named as an accepted
  slice-scale risk with a pre-external-exposure fairness requirement
  (Section 8.2.2).
- No API endpoint shapes (Node A), no UX, no Wave-1 file modified, no
  infrastructure created.
