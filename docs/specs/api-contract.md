# API Contract — First Vertical Slice (Sprint 0001, Node A)

Status: contract document for Sprint 0001, Wave 2. Documentation only; no runnable
code. Machine-readable companion: `docs/specs/api.openapi.yaml` (OpenAPI 3.0.3 —
normative for request/response shapes; this prose is normative for behavior).

Frozen upstream inputs (never modified here):
- `docs/specs/product-behavior.md` (P) — screens, P-AUTH rules, error semantics,
  acceptance criteria.
- `docs/specs/domain-model.md` and `docs/specs/database-contract.md` (D) — objects,
  transaction boundary, idempotency, receipt/outbox mechanics.
- `docs/specs/local-topology.md` (I) — ports, env, dev-token guard.
- `docs/specs/WAVE1_FREEZE.md` — Obligation 3 (browser inspection surface) is
  discharged by §9 of this contract.

This contract is the edge between the Sprint-0002 frontend-builder and
backend-builder. The browser talks only to this API; it never writes to PostgreSQL,
Kafka, or any store directly (charter invariant).

---

## 1. Conventions

- **Base URL (local):** `http://127.0.0.1:${API_PORT}` (default `3001`, loopback
  only — I §4/§9). All business endpoints are versioned under the path prefix `/v1`.
- **Media type:** requests and responses are `application/json; charset=utf-8`.
  A request body that is not parseable JSON is rejected `400` with error code
  `invalid_request` (nothing created).
- **Identifiers:** all IDs are server-generated UUIDs (D identifier rule). Clients
  never supply IDs for authoritative records.
- **Timestamps:** RFC 3339 / ISO-8601 UTC `date-time` strings (e.g.
  `2026-08-20T17:03:00.000Z`).
- **Calendar dates:** RFC 3339 `full-date` strings, `YYYY-MM-DD` (used by
  `next_action_date` / `due_on`), interpreted against the tenant's
  `operating_timezone` (D timestamp rule).
- **Outcome values:** the closed token list owned by P §1 — `connected`,
  `no_answer`, `left_voicemail`, `meeting_scheduled`, `not_interested`. The API
  accepts and returns **stored tokens only**. User-visible labels are the UI's
  rendering concern per P's token→label table; the API never transports labels.
- **Server-assigned fields:** Interaction.occurred_at is assigned server-side at
  write time. It is not a request field; any client attempt to supply it is
  rejected by the closed request schema as an unknown field. (D §2.6.) Task titles are
  generated server-side from P's outcome→title table and returned in responses —
  never client-supplied.
- **Unknown fields:** request bodies are validated closed (`additionalProperties:
  false`); an unknown field is a validation failure (`400`, field-level error),
  nothing created. This keeps the request hash (§6) unambiguous.

## 2. Authentication, current user, and active tenant

### 2.1 Dev-token header

- Header name: **`X-Dev-Token`** (a dedicated header, not `Authorization`, so the
  dev stub is a cleanly removable seam and P-AUTH-5's "no production configuration
  documents or accepts the dev-token header" is checkable by header name). Value:
  an opaque seeded token (I §9 — ≥128-bit random, stored only in the local
  database, never committed).
- Availability of this mechanism is gated by I §9's multi-factor `AUTH_MODE=dev-token`
  guard. Only credential verification is stubbed; the rest of the pipeline is real
  (P §2 preamble).

### 2.2 Request pipeline (every `/v1` endpoint, no exceptions)

Order is fixed and testable (P §7 closing note: auth precedes validation;
validation precedes the transaction):

1. **Authenticate** — resolve `X-Dev-Token` to a User. Missing, unknown, or
   malformed token → `401 unauthenticated` (P-AUTH-2). A token resolving to a
   **deactivated** user also fails here → `401` with the identical body
   (D §2.2: a deactivated user fails authentication; the public response does not
   reveal that the token was once valid) (P-AUTH-7).
2. **Resolve active tenant + membership** — the token binds exactly one user and
   one active tenant (P-AUTH-3/3a). Membership in the active tenant is verified on
   every request, never cached (P-AUTH-3b). No membership or revoked membership →
   `403 unauthorized` (P-AUTH-4). Suspended tenant → `403 unauthorized`
   (P-AUTH-6). The `403` body is one generic constant (§4) — it does not
   distinguish revoked vs. absent membership vs. suspended tenant.
3. **Authorize + tenant-scope record lookups** — every record addressed by path or
   body is looked up with an explicit `tenant_id` predicate. Cross-tenant or
   nonexistent → `404 not_found` with the identical constant body (§5).
4. **Validate** — closed-vocabulary, presence, format, and date rules (§7 per
   endpoint). Failure → `400 validation_failed` with field-level errors; nothing
   is created (P §5.2/5.3).
5. **Transact** — writes execute inside one PostgreSQL transaction whose statement
   zero is the shared `withTenantWrite` membership/tenant recheck (D §2;
   WAVE1_FREEZE Obligation 1). The concurrent-revocation/suspension race resolves
   per P-AUTH-3b: a write that commits proves membership and tenant were active at
   commit time; a recheck failure aborts with nothing written and returns `403`.
6. **Return IDs / representations.**

**Denial logging (P-AUTH-8, sole source of truth):** every denial from steps 1–3 —
including cross-tenant lookups surfaced publicly as `404` (P §5.4) — is
server-logged with exactly the canonical P-AUTH-8 field set (actor claim as
presented, tenant as requested if resolvable, route, timestamp; token values are
never logged). This contract references P-AUTH-8 and deliberately does not redefine
its fields (I §7 records where the log stream lives).

### 2.3 Pipeline exceptions

`GET /livez` and `GET /readyz` (owned by I §7) are unauthenticated infrastructure
health endpoints. They return no tenant data and perform no writes; they are the
only endpoints outside the P-AUTH pipeline. Their semantics are defined by I; the
OpenAPI file mirrors them for completeness without redefining them.

### 2.4 CurrentUser endpoint

`GET /v1/me` returns the resolved acting user (id, display name, email) and active
tenant (id, name, `operating_timezone`), so the UI can display "who am I acting as
and where" (P-AUTH-3) and compute date-picker hints in the tenant's zone (the
server remains the authority for date validation, §7.7).

## 3. Standard error envelope

One envelope for every non-2xx response:

```json
{
  "error": {
    "code": "<machine token>",
    "message": "<safe human-readable summary>",
    "field_errors": [
      { "field": "<request field name>", "code": "<machine token>", "message": "<text>" }
    ]
  }
}
```

- `field_errors` is present **only** for `validation_failed` and contains at least
  one entry; each entry names the offending request field (e.g.
  `next_action_date`, `outcome`, `name`, `full_name`) or the header name
  `Idempotency-Key` when the header itself is missing/oversized.
- Error `code` values and their statuses:

| HTTP status | `error.code` | When |
|---|---|---|
| 400 | `invalid_request` | Unparseable JSON body, wrong content type. |
| 400 | `validation_failed` | Field-level validation failure; `field_errors` present; nothing created. |
| 401 | `unauthenticated` | P-AUTH-2 (no/unknown/malformed token) and P-AUTH-7 (deactivated user). |
| 403 | `unauthorized` | P-AUTH-4 (no/revoked membership), P-AUTH-6 (suspended tenant), in-transaction recheck failure. |
| 404 | `not_found` | Nonexistent record **or** cross-tenant record (§5). |
| 409 | `idempotency_key_conflict` | Same idempotency key, different payload (§6). |

- Messages never contain token material, other tenants' data, raw event payloads,
  or internal identifiers (`seq`, `claim_id`).

## 4. Constant denial bodies

These exact bodies are constants (no per-request substitution, no ID echo), which
makes the P §5.4 "identical status and body" guarantee trivially byte-comparable:

- `401` → `{"error":{"code":"unauthenticated","message":"Authentication required."}}`
- `403` → `{"error":{"code":"unauthorized","message":"Not authorized for this tenant."}}`
- `404` → `{"error":{"code":"not_found","message":"Not found."}}`

## 5. Tenant scoping and not-found semantics

- Every `/v1` endpoint operates strictly within the token's active tenant. There is
  no cross-tenant read or write under any role (D §2.3).
- **Cross-tenant is indistinguishable from nonexistent (P §5.4): the public status
  is `404` with the constant §4 body**, for reads and writes alike, including the
  inspection endpoint (§9) and referenced parents (a `companyId` or `contactId`
  path segment that fails the tenant-scoped lookup — P §5.7). Nothing is created
  in either tenant; the attempt never appears in any tenant's audit view; it is
  server-logged as a denial per P-AUTH-8.
- Timing side-channel equivalence is explicitly out of scope (P §5.4).
- There is no public "forbidden for this record" response: `403` is reserved for
  requester-level denials (membership/tenant status), which leak nothing about any
  record.

## 6. Idempotency (log-interaction)

- Header name: **`Idempotency-Key`**. Opaque client string, 1–200 characters
  (D §3). **Required** on `POST /v1/contacts/{contactId}/interactions`; a missing
  or oversized key is `400 validation_failed` (field `Idempotency-Key`), nothing
  created. The header carries no idempotency semantics on any other endpoint in
  this slice and is ignored there (documented so clients do not rely on it).
- **Scope:** `(tenant_id, actor_user_id, operation = "log-interaction", key)` —
  exactly D §3's primary key. Different tenants, different actors, or different
  operations reusing the same key string never collide.
- **Request hash:** the server hashes the canonical semantic payload — the
  tenant-scoped `contactId` from the path plus the canonicalized JSON body fields
  (`outcome`, `notes`, `next_action_date`) — and stores it on the key row.
  Canonicalization (stable key order, absent-vs-null normalization) is an
  implementation detail behind this contract; the observable rule is: two requests
  are "the same payload" iff their semantic field values are equal.
- **Replay (sequential duplicate):** same scoped key, same payload, original
  completed → `200` with the same response body as the original success: the same
  `interaction` and `task` objects with the **same IDs**. No writes occur (D §3);
  no second audit creation appears (P §5.1).
- **Hash mismatch:** same scoped key, different payload → `409
  idempotency_key_conflict`. Nothing is created; the original interaction and task
  are unchanged (P §5.1).
- **Concurrent duplicates:** two in-flight requests with the same scoped key and
  payload → exactly one creation; both responses are successful (`201` for the
  transaction that created, `200` for the replay) and both carry the **same**
  interaction and task IDs (P §5.1, D §3 blocking flow). If the first transaction
  rolls back, the key is freed and the second proceeds as a fresh creation.
- The first-creation success status is `201 Created`; replays are `200 OK`. Both
  satisfy P §5.1's "both responses are successful".
- **Binding rule (when a key becomes bound):** the idempotency row is created
  *inside* the write transaction (D §2 statement 1) and rolls back with it, and
  validation precedes the transaction (§2.2). Therefore a request that fails
  before commit — `400` validation, `401`/`403` denial, `404` lookup, or any
  rolled-back transaction — binds **nothing**: no key row survives, and the
  client **may reuse the same key** with a corrected (different) payload; only a
  **committed creation** binds the key and its request hash, and the `409`
  hash-mismatch rule is evaluated only against such a completed key row. This is
  exactly P §3.5's form behavior: one key per form instance, reused across
  retries including corrected resubmissions after validation errors. (A key held
  by a concurrent in-flight transaction blocks per D §3 until that transaction
  commits or rolls back, then resolves by the rules above.)

## 7. Endpoints

Inventory (all under the §2.2 pipeline; write sets name every row committed in the
single transaction, per D):

| # | Method + path | Purpose (P ref) |
|---|---|---|
| 1 | `GET /v1/me` | Acting user + active tenant (P-AUTH-3). |
| 2 | `GET /v1/companies` | Companies screen list (P §3.2). |
| 3 | `POST /v1/companies` | Create company (P §3.2). |
| 4 | `GET /v1/companies/{companyId}` | Company screen: company + its contacts (P §3.3). |
| 5 | `POST /v1/companies/{companyId}/contacts` | Create contact (P §3.3). |
| 6 | `GET /v1/contacts/{contactId}` | Contact header data (P §3.4). |
| 7 | `GET /v1/contacts/{contactId}/interactions` | Timeline (P §3.4). |
| 8 | `POST /v1/contacts/{contactId}/interactions` | Log interaction — the transactional write (P §3.5, D §2). |
| 9 | `GET /v1/tasks` | Home: acting user's open next-action tasks (P §3.1). |
| 10 | `GET /v1/audit-events` | Audit view (P §3.6). |
| 11 | `GET /v1/interactions/{interactionId}/processing-status` | Event-processing inspection (P §6.4; Obligation 3) — §9. |
| — | `GET /livez`, `GET /readyz` | Health (owned by I §7; outside the pipeline, no tenant data). |

### 7.1 `GET /v1/me`

Returns `{ user: { id, display_name, email }, tenant: { id, name,
operating_timezone } }`. Read-only; no writes; errors: 401/403 only.

### 7.2 `GET /v1/companies`

- Returns the active tenant's companies. Each item: `id`, `tenant_id`, `name`,
  `contact_count` (count of the company's contacts), `created_at`, `updated_at`
  (P §3.2 row contents).
- **Ordering (deterministic, P §3.2):** `lower(name)` ascending, ties by `id`
  ascending. Paginated (§8).
- Empty tenant → `200` with empty `items` (the UI renders P's empty state; an
  empty list is never an error).

### 7.3 `POST /v1/companies`

- Request: `{ "name": string }`. `name` is required, non-empty after trimming
  leading/trailing whitespace, ≤ 300 chars (D §4 bound); the trimmed value is
  stored. Blank/whitespace-only → `400 validation_failed`, field `name`, nothing
  created (P §3.2).
- Response `201`: the created Company (as in §7.2, `contact_count` = 0).
- **Transactional write set (one transaction):** `withTenantWrite` recheck →
  insert `company` → append `audit_event` (`action = "company.created"`,
  `record_type = "company"`, `record_id` = company id). **No outbox row**: in this
  slice the only event type is `interaction.logged` (D §2/§4; Node E's scope);
  company creation is audited but not published.

### 7.4 `GET /v1/companies/{companyId}`

- Tenant-scoped lookup; cross-tenant/nonexistent → `404` (§5).
- Response `200`: the Company (with `contact_count`) plus `contacts`: the
  company's contacts, each with `id`, `tenant_id`, `company_id`, `full_name`,
  `email` (nullable), `phone` (nullable), `last_contacted_at` (nullable — `null`
  is the API representation of P's "never contacted"), `created_at`.
- Absent optional fields are `null` in JSON; the UI simply does not render them
  (P §3.4 test).
- **Contact ordering (Node A determinism choice; P does not mandate one):**
  `lower(full_name)` ascending, ties by `id` ascending. The embedded list is
  unpaginated in this slice (P's paginated surfaces are §8's four lists; slice
  scale makes this safe; pagination here would be an additive change).

### 7.5 `POST /v1/companies/{companyId}/contacts`

- Parent company resolved tenant-scoped; failure → `404` (P §5.7), nothing
  created.
- Request: `{ "full_name": string, "email"?: string|null, "phone"?: string|null }`.
  `full_name` required, non-empty after trim, ≤ 300 chars. `email`/`phone`
  optional; omitted and `null` are equivalent (stored `NULL`); when present,
  non-empty after trim. No email-format validation beyond length in this slice
  (D §2.5 imposes none; additive later).
- Response `201`: the created Contact (shape as in §7.4, `last_contacted_at:
  null`).
- **Transactional write set (one transaction):** `withTenantWrite` recheck →
  insert `contact` (composite-FK-bound to the same-tenant company) → append
  `audit_event` (`action = "contact.created"`, `record_type = "contact"`). No
  outbox row (same rationale as §7.3).

### 7.6 `GET /v1/contacts/{contactId}`

- Tenant-scoped; `404` per §5.
- Response `200`: Contact (as §7.4) plus `company: { id, name }` so the contact
  screen renders the owning company (P §3.4). `last_contacted_at: null` ⇒ UI
  "never contacted".

### 7.7 `GET /v1/contacts/{contactId}/interactions`

- Tenant-scoped contact lookup; `404` per §5.
- Returns the contact's timeline entries: `id`, `tenant_id`, `contact_id`, `kind`
  (`"call"`), `outcome` (token), `notes` (nullable), `occurred_at`, `created_by:
  { user_id, display_name }` (the acting user, renderable per P §1 timeline-entry
  definition), `created_at`.
- **Ordering (deterministic):** `occurred_at` descending (newest first, P §3.4),
  ties by `id` ascending. Paginated (§8).

### 7.8 `POST /v1/contacts/{contactId}/interactions` — log interaction

The slice's core transactional write (D §2). Headers: `X-Dev-Token` (required),
`Idempotency-Key` (required, §6).

- Tenant-scoped contact lookup; cross-tenant/nonexistent → `404`, nothing created
  in either tenant (P §5.4/5.7).
- Request body (closed):

  ```json
  {
    "outcome": "connected | no_answer | left_voicemail | meeting_scheduled | not_interested",
    "notes": "optional free text (or null)",
    "next_action_date": "YYYY-MM-DD"
  }
  ```

  - `outcome`: required; must be one of the five P tokens. Missing/unknown →
    `400 validation_failed`, field `outcome` (P §5.3).
  - `notes`: optional; omitted and `null` equivalent.
  - `next_action_date`: required `full-date`; must be **today or later where
    "today" is the current date in the tenant's `operating_timezone`** (P §5.2 —
    today is valid; server-evaluated; the seeded `Pacific/Kiritimati` boundary
    test exercises this). Missing/unparseable/past → `400 validation_failed`,
    field `next_action_date`.
  - There is **no** `occurred_at`, no `kind`, no `title`, and no ID field in the
    request: `occurred_at` is server-assigned transaction time, `kind` is fixed
    `"call"`, and the task title is server-generated from P's outcome→title table.
  - Validation failure creates nothing — no interaction, task, timeline entry,
    last-contacted change, audit event, idempotency completion, or outbox event
    (P §5.2).
- Response `201` (creation) / `200` (idempotent replay, §6), same body shape:

  ```json
  {
    "interaction": { "id", "tenant_id", "contact_id", "kind", "outcome", "notes",
                     "occurred_at", "created_by": { "user_id", "display_name" },
                     "created_at" },
    "task": { "id", "tenant_id", "contact_id", "interaction_id", "title",
              "due_on", "status", "assigned_to", "created_at" }
  }
  ```

  `task.title` is the exact generated title from P's table; `task.due_on` equals
  the request's `next_action_date`; `task.status` is `"open"`;
  `task.assigned_to` is the acting user's id (P §1). The response returns both IDs
  (FIRST_VERTICAL_SLICE synchronous step 6); duplicate submissions receive the
  same IDs (AC-3).
- **Transactional write set — ONE PostgreSQL transaction, exactly D §2:**
  1. `withTenantWrite` recheck (statement zero).
  2. `idempotency_key` reservation (`ON CONFLICT DO NOTHING`; replay/conflict
     branch per D §3 and §6 above).
  3. Insert `interaction` (`occurred_at` = server transaction time).
  4. Update `contact.last_contacted_at` (forward-only `GREATEST`).
  5. Insert exactly one `task` (`status = "open"`, generated title, `due_on`).
  6. Append `audit_event` (`action = "interaction.logged"`, `record_type =
     "interaction"`, `record_id` = interaction id, `details` carrying
     `task_id` and the `outcome` token — this is how the audit view lets a tester
     tie the interaction and its task to one submission, P §3.6).
  7. Append `outbox_event` (`event_type = "interaction.logged"`,
     `aggregate_type = "interaction"`, `aggregate_id` = interaction id,
     `aggregate_version` = 1, payload = Node E's envelope with envelope
     `event_id` = outbox row `id`, `status = "pending"`).
  8. Complete the `idempotency_key` row with both result IDs.

  All commit together or not at all; the transaction performs no network calls
  (publication is asynchronous, D §5). All P §4 step-5 observations are visible
  immediately after the `201`, with the worker stopped (P §6.1).

### 7.9 `GET /v1/tasks`

- Returns the **acting user's open** next-action tasks in the active tenant
  (P §3.1): filter `assigned_to = current user`, `status = "open"`, fixed in this
  slice (no status/assignee parameters; task lifecycle beyond open is a non-goal,
  P §8).
- Each item is denormalized for the home screen: `id`, `tenant_id`, `title`
  (generated), `due_on`, `status`, `contact: { id, full_name }`, `company: { id,
  name }`, `interaction_id`, `interaction_outcome` (the causing interaction's
  outcome **token**; the UI renders P's label), `created_at`.
- **Ordering (exactly P §3.1):** `due_on` ascending, ties by `created_at`
  ascending, remaining ties by `id` ascending. Paginated (§8).
- Done tasks never appear. Empty → `200` empty `items` (UI renders P's empty
  state).

### 7.10 `GET /v1/audit-events`

- Returns the active tenant's audit events (all actors in the tenant — the audit
  view is tenant-wide, P §3.6). Each item: `id`, `tenant_id`, `actor: { user_id,
  display_name }`, `action` (e.g. `company.created`, `contact.created`,
  `interaction.logged`), `record_type`, `record_id`, `occurred_at`, `details`
  (small structured object per D §2.8; for `interaction.logged` it includes
  `task_id` and `outcome`). Those fields cover P's five required dimensions:
  actor, tenant, action, record, time (AC-8).
- **Ordering (deterministic):** `occurred_at` descending (newest first, P §3.6),
  ties by `id` ascending. Paginated (§8).
- Read-only; reads are not audited in this slice.

## 8. Pagination conventions

Applies to the four list surfaces: companies (§7.2), timeline (§7.7), tasks
(§7.9), audit events (§7.10).

- Query parameters: `limit` (integer, default 50, min 1, max 200) and `offset`
  (integer, default 0, min 0). Out-of-range values → `400 validation_failed`.
- Response wrapper:

  ```json
  { "items": [ ... ], "pagination": { "limit": 50, "offset": 0, "total": 123 } }
  ```

  `total` is the total matching row count under the endpoint's fixed filter and
  the active tenant.
- Determinism: every list has a fully specified total order with a unique final
  tiebreaker (`id`), so identical requests against identical data return
  identical pages (P §3.1's repeated-loads test generalizes).
- Offset+limit is deliberately minimal for slice scale; cursors would be an
  additive future change behind the same wrapper.

## 9. Event-processing inspection endpoint (WAVE1_FREEZE Obligation 3)

### `GET /v1/interactions/{interactionId}/processing-status`

Closes the deferred browser-only portion of AC-1 journey step 6: after logging an
interaction, the browser polls this endpoint until `state` is `"processed"`
(within the 30-second CI bound, P §4 step 6). Once this ships, processing-state
assertions move from the P §6.6 database carve-out to this surface.

- **Security — identical to every other endpoint (P §6.4):** full §2.2 pipeline
  (dev-token authentication, active-tenant membership resolution on every request,
  authorization, tenant scoping). Tenant A querying tenant B's interaction — or
  any nonexistent interaction id — receives the identical `404` constant body
  (§4/§5). Unauthenticated → `401` (P-AUTH-2). Denials logged per P-AUTH-8.
- **Lookup:** tenant-scoped interaction, then its outbox event via the aggregate
  linkage (`tenant_id`, `aggregate_type = "interaction"`, `aggregate_id` =
  interaction id — D §7.2), then the required consumer's receipt via
  `(tenant_id, event_id)`. Every committed interaction has its outbox row by
  construction (D §2), so a found interaction always yields a status.
- Read-only; no writes, no audit rows.
- Response `200`:

  ```json
  {
    "interaction_id": "uuid",
    "event_id": "uuid",
    "event_type": "interaction.logged",
    "state": "pending | published | processed | failed",
    "staged_at": "date-time (outbox row created_at)",
    "published_at": "date-time | null",
    "processed_at": "date-time | null",
    "publication": {
      "attempt_count": 0,
      "last_error": "sanitized summary | null"
    },
    "consumer": {
      "status": "processing | processed | failed",
      "attempt_count": 1,
      "first_seen_at": "date-time",
      "last_attempt_at": "date-time",
      "processed_at": "date-time | null",
      "last_error": "sanitized summary | null"
    } ,
    "failure": {
      "failure_stage": "publication | consumer",
      "last_error": "sanitized summary",
      "secondary": {
        "stage": "consumer",
        "last_error": "sanitized summary | null",
        "attempt_count": 1,
        "last_attempt_at": "date-time"
      }
    }
  }
  ```

  - `consumer` is `null` until the required consumer has recorded a receipt;
    `failure` is `null` unless `state` is `"failed"`; `failure.secondary` is
    `null` unless both stages hold failure evidence.
  - `event_id` is the outbox row id, which the frozen Node E seam pins equal to
    the envelope's `event_id` (D §2.9) — this is the aggregate linkage this
    endpoint may reference; envelope/topic design remains Node E's.
- **State derivation — exactly D §7.1's strict precedence (first match wins):**
  1. `processed` — the required consumer's receipt status is `processed`
     (`processed_at` populated).
  2. `failed` — outbox status is `failed` **or** the receipt status is `failed`.
     `failure.failure_stage` is `"publication"` when the outbox is failed
     (`failure.last_error` = the outbox's sanitized last error) and `"consumer"`
     when only the receipt is failed (`failure.last_error` = the receipt's).
     **Publication-first tie-break (P §6.4):** when both stages hold failure
     evidence, `failure_stage` is `"publication"` and the consumer failure is
     returned as the secondary diagnostic block (`failure.secondary`). The
     tie-break is presentation precedence only; both underlying records remain
     visible (the receipt detail also appears under `consumer`).
  3. `published` — outbox status is `published` (`published_at` set); a
     `processing` receipt, if any, is visible as attempt detail under `consumer`.
  4. `pending` — otherwise, **including while an active publication lease is
     held** (P §1 publication lease: pending is the lease's only observable
     effect). Honest gloss (D §7.1): pending means *not yet confirmed published —
     the event may already be in the stream*; at-least-once consumers make this
     safe.

  The four states are mutually exclusive by construction; the browser journey can
  observe all four (pending with attempt/last-error detail, published, processed,
  failed with stage and errors), satisfying Obligation 3.
- **Confidentiality — response allowlist (D §7.1 rule; Obligation 3; defense in
  depth):** the response contains **exactly** the fields declared above —
  `interaction_id`, `event_id`, `event_type`, `state`, `staged_at`,
  `published_at`, `processed_at`, `publication` (`attempt_count`, `last_error`),
  `consumer` (receipt status/attempts/timestamps/`last_error`), and `failure`
  (`failure_stage`, `last_error`, `secondary`) — and nothing else; the OpenAPI
  `ProcessingStatus` schema enforces this with `additionalProperties: false`.
  In particular the response **never** exposes: **Kafka topic, Kafka partition,
  Kafka offset, `seq`, `claim_id`, `claimed_by`, `lease_expires_at`**, the raw
  envelope `payload`, or any cross-tenant data. Every `last_error` field carries
  **only the contractually sanitized error code and safe operator-facing
  summary** mandated by WAVE1_FREEZE Obligation 2 — never credentials, tokens,
  payload contents, notes, email bodies, or broker coordinates. Node E
  simultaneously bans topic/partition/offset from `last_error` at the source;
  this allowlist is the API's independent defense-in-depth layer, so a value
  that escapes source sanitization still has no field through which broker or
  coordination detail could reach a tenant. Lease internals are additionally
  withheld because P §6.4/§1 declare the publication lease internal, with
  pending-state as its only observable effect; operators retain database-level
  access (P §6.6 residual carve-out).

## 10. Traceability: P screens and acceptance criteria → API

| P surface / criterion | Endpoint(s) |
|---|---|
| §3.1 Home (open tasks, deterministic order, empty state) | §7.9 `GET /v1/tasks` |
| §3.2 Companies list + create (+ empty state, validation) | §7.2 `GET /v1/companies`, §7.3 `POST /v1/companies` |
| §3.3 Company screen (contacts, create contact) | §7.4 `GET /v1/companies/{id}`, §7.5 `POST /v1/companies/{id}/contacts` |
| §3.4 Contact + timeline (+ never contacted, optional fields) | §7.6 `GET /v1/contacts/{id}`, §7.7 `GET .../interactions` |
| §3.5 Log-interaction form (outcome list, date rule, idempotency) | §7.8 `POST /v1/contacts/{id}/interactions` |
| §3.6 Audit view (five dimensions, submission linkage) | §7.10 `GET /v1/audit-events` |
| §2 identity display (P-AUTH-3) | §7.1 `GET /v1/me` |
| §6.4 processing state / AC-1 step 6 | §9 inspection endpoint |
| AC-1 full journey | §7.1→§7.3→§7.5→§7.8→§7.7/§7.9/§7.10→§9 |
| AC-2 tenant isolation | §2.2, §5 on every endpoint; §5.4 test via any record endpoint |
| AC-3 idempotent duplicate HTTP | §6 + §7.8 (same IDs; 409 on hash mismatch; concurrent case) |
| AC-4/AC-5 duplicate delivery / worker restart | Observable through §9 (receipt/state; counts via §7.7/§7.9) |
| AC-6 timeline shows interaction | §7.7 |
| AC-7 home shows open task | §7.9 |
| AC-8 audit five fields | §7.10 |
| AC-9 automated tests | Every behavior above is stated as status+body+ordering assertions |
| P §5.2/5.3 validation (nothing created) | §7.8 `400` semantics; verified via §7.7/§7.9/§7.10 re-reads |
| P §5.6 unauthenticated / P-AUTH-6/7 | §2.2 statuses on every endpoint |

## 11. Non-goals (API surface deliberately absent)

Per P §8: no task completion/edit endpoints (tasks stay open), no company/contact/
interaction update or delete, no search endpoints, no tenant/user/membership
administration endpoints (fixtures are seeded; any future membership endpoint must
emit `membership.granted`/`membership.revoked` audit events per D §2.3), no
reporting, no rate limiting (pre-exposure future requirement), no event
envelope/topic definitions (Node E), no UI specification (Node U).

## 12. Seam answers routed from Node U

Four UX-architecture seam questions, answered normatively:

1. **Tenant operating timezone exposure — yes.** `GET /v1/me` (§7.1) returns
   `tenant.operating_timezone` (the IANA identifier), so the client can compute
   tenant-local "today" and pre-validate / constrain the next-action date picker.
   Server-side validation in the tenant's zone (§7.8) remains authoritative in
   all cases; client pre-validation is a courtesy only.
2. **Validation failure does not bind the idempotency key.** Per the §6 binding
   rule: a `400` (or any pre-commit failure) leaves no idempotency row, so the
   client may reuse the same `Idempotency-Key` with the corrected — therefore
   different — payload; no key regeneration is required after a validation
   error. Only a committed creation binds the key + request hash; `409` applies
   only after such a commit.
3. **The success response carries the complete next-action task record — no
   additional request needed.** §7.8's `201`/`200` body includes the complete `task` object:
   server-generated `title` (P's exact outcome→title string), `due_on`,
   `status: "open"`, `contact_id`, `interaction_id`, `assigned_to`, `created_at`
   — sufficient for the confirmation UI ("interaction logged and next-action
   task created", P §3.5) without calling `GET /v1/tasks`.
4. **Submission correlation in the audit view:** the `interaction.logged` audit
   event carries `record_type = "interaction"`, `record_id` = the interaction id,
   and `details.task_id` = the created task id (plus `details.outcome`). Matching
   `record_id` to the timeline entry's `id` and `details.task_id` to the home
   task's `id` proves both records came from the same submission (P §3.6); the
   same pair also appears together in §7.8's response body.

## 13. Self-verification checklist

- Every P user action maps to an endpoint: §10 table; all six screens plus
  sign-in display and the async observation are covered.
- Every P acceptance criterion is executable through this API: §10 (AC-1..AC-9).
- Field semantics match D exactly: `due_on` is a calendar date; `occurred_at` is
  server-assigned; outcome tokens are P's closed list; generated titles are
  returned, never client-supplied; `last_contacted_at` nullable/forward-only.
- One error envelope for validation, auth, and not-found: §3; constant denial
  bodies: §4.
- Cross-tenant ≡ nonexistent, status `404`, identical body, on every endpoint
  including inspection: §5, §9.
- Idempotency: header named, D §3 scope, replay returns same IDs, `409` on hash
  mismatch, concurrent duplicates both succeed with same IDs: §6.
- Transactional write sets named per mutating endpoint (§7.3, §7.5, §7.8);
  log-interaction commits interaction + contact update + task + audit + outbox +
  idempotency rows in one transaction (D §2).
- Obligation 3 discharged: authenticated, active-tenant-scoped, cross-tenant
  not-found, all four states with `failure_stage`, publication-first tie-break,
  last error, secondary consumer detail: §9.
- Confidentiality checked mechanically against the OpenAPI file: `seq`,
  `claim_id`, `claimed_by`, `lease_expires_at`, and `payload` appear in no
  response schema anywhere; the `ProcessingStatus` subtree additionally bans
  Kafka topic/partition/offset property names and its top-level properties match
  the §9 allowlist exactly; lease internals withheld with rationale: §9.
- No endpoint bypasses the P-AUTH pipeline except I-owned `/livez`/`/readyz`,
  which return no tenant data: §2.3.
- Denial logging references P-AUTH-8 as sole source; no field list redefined: §2.2.
- No tenth object introduced; no Wave-1 contract edited.
