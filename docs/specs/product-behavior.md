# Product Behavior Contract — First Vertical Slice

Status: Revision after Wave-1 barrier ruling (Sprint 0001)
Owner: Node P (Product behavior)
Scope source: `docs/FIRST_VERTICAL_SLICE.md`, `docs/PROJECT_CHARTER.md`

This document defines the observable behavior of the first vertical slice. It describes what a salesperson (and a tester) can see and do. It does not define API endpoint shapes (Node A), the domain model (Node D), or infrastructure. Every behavior below must be verifiable through the web UI or the CRM API by a tester with no access to internal implementation, with one stated exception: the QA carve-out in Section 6.6, which permits database-level assertions for outbox/processing state until the Node A inspection surface exists.

**Terminology ruling:** the product term is **next-action task** and **next-action date**. Where `docs/FIRST_VERTICAL_SLICE.md` says "follow-up task" or "follow-up", this contract's next-action task/date is the same thing; a next action does not necessarily mean another outreach to the contact. Verbatim quotes from the source document are preserved in Section 7 and mapped to next-action behavior.

---

## 1. Definitions

Every noun used in this contract is defined here. No behavior in this document requires objects beyond: Tenant, User, Membership, Company, Contact, Interaction, Task, Audit event, Outbox event.

- **Tenant** — the isolation boundary that owns all business records. Every company, contact, interaction, task, audit event, and outbox event belongs to exactly one tenant. Every tenant has a required **operating timezone** and a status of **active** or **suspended**.
- **Suspended tenant** — a tenant whose status is suspended. No request may act within a suspended tenant (P-AUTH-6), regardless of valid credentials or membership.
- **Operating timezone (`Tenant.operating_timezone`)** — a required tenant property holding an IANA timezone identifier (for example `America/Los_Angeles`). It defines what "today" means for that tenant: next-action-date validation ("today or later", Section 5.2) is evaluated against the current date in the tenant's operating timezone, not the server's or the browser's timezone.
- **User** — an identity that can act in the system, with a status of **active** or **deactivated**. A user may hold memberships in multiple tenants, but every request carries exactly one **active tenant** context, and the user acts only within that tenant for that request.
- **Deactivated user** — a user whose status is deactivated. A deactivated user cannot act at all (P-AUTH-7), even with an otherwise valid token and membership.
- **Membership** — the association between a user and a tenant that grants the user the right to act inside that tenant. A user may have zero, one, or many memberships. A membership can be **revoked**; a revoked membership grants no access and behaves exactly as if no membership existed. The membership for the request's active tenant is independently verified on every request; a user with no (or only a revoked) membership in the active tenant has no access to any of that tenant's records, regardless of memberships elsewhere.
- **Active tenant** — the single tenant context attached to a request. With the dev-token stub, each seeded dev token binds one user to one active tenant (Section 2); switching tenants means presenting a different token.
- **Company** — a business record representing an organization the salesperson sells to. Minimum user-visible attribute: a required non-empty name.
- **Contact** — a business record representing a person, associated with exactly one company in the same tenant. User-visible attributes: a required non-empty name, an **optional email**, an **optional phone**, and the owning company. A contact also displays a **last-contacted timestamp**: the date-time of the most recent interaction logged against that contact, or an explicit "never contacted" state if none exists.
- **Interaction** — a record of a communication with a contact. In this slice the only interaction type is a **call**. An interaction has: the contact it belongs to, a required **outcome**, an optional free-text note, a required **next-action date**, the acting user, and the date-time it was logged.
- **Next-action date** — the required date the salesperson sets when logging an interaction, stating when the next action for this relationship is due. It becomes the due date of the generated next-action task. It must be today or later in the tenant's operating timezone.
- **Outcome** — a required classification of the call chosen from the closed, seeded list defined below. This vocabulary is a product decision owned by this contract. The stored token is the exact value accepted by the API; the user-visible label is the exact text rendered in the form and on timeline entries. Free-typed outcome values are not accepted, and no other values are valid in this slice.

  | Stored token | User-visible label | Meaning |
  |---|---|---|
  | `connected` | Connected | Spoke with the contact. |
  | `no_answer` | No answer | Call placed; no one answered and no message was left. |
  | `left_voicemail` | Left voicemail | Call placed; a voicemail was left. |
  | `meeting_scheduled` | Meeting scheduled | Spoke with the contact and a meeting was agreed. |
  | `not_interested` | Not interested now | Spoke with the contact; they declined engagement at this time. |

  The form presents exactly these five labels, in this order, as a selection control. Every outcome — including `not_interested` — still results in exactly one next-action task (the invariant is unchanged); for `not_interested` the next action is a disposition review, not necessarily another outreach.
- **Task (next-action task)** — a work item created as a consequence of logging an interaction. A task has: a **generated title** (below), the contact it relates to, the interaction that caused it, a due date (the next-action date), a status of **open** or **done**, and the user it is assigned to (in this slice, the acting user). "Open next-action task" means a task whose status is open.
- **Generated task title** — a deterministic title assigned at task creation from the interaction's outcome token, with `{contact name}` replaced by the contact's name at creation time. The exact titles are:

  | Outcome token | Exact generated task title |
  |---|---|
  | `connected` | Continue the conversation with {contact name}. |
  | `no_answer` | Call {contact name} again. |
  | `left_voicemail` | Await a reply or call {contact name} again. |
  | `meeting_scheduled` | Prepare for the meeting with {contact name}. |
  | `not_interested` | Review disposition: close out or set a re-engagement date. |

  Titles are fixed at creation (tasks are not editable in this slice) and are exact, testable strings.
- **Timeline** — the chronological list of interactions for a contact, newest first, shown on the contact screen. A **timeline entry** displays: interaction type (call), outcome label, note (if any), acting user, and logged date-time.
- **Audit event** — an immutable record of a meaningful write, visible in the audit view. Each audit event identifies: **actor** (the user), **tenant**, **action** (what kind of change), **record** (which business record was affected), and **time**.
- **Outbox event** — a durable event appended in the same transaction as the write it describes, later published to the event stream. Its only *user-visible* manifestations are the inspectable **processing state** and **processing receipt** (Section 6.4); its wire format is out of scope here.
- **Processing receipt** — the consumer's durable record that it completed processing a given outbox event. It is the processing-state record of the Outbox event, not a tenth business object. In this slice the receipt **is** the consumer's entire side effect (Section 6.5).
- **Publication lease** — a worker's temporary claim on an outbox event while it attempts publication. It is internal; its only observable effect is that the event's state remains **pending** while the lease is active (Section 6.4).
- **Idempotency key** — a client-supplied opaque token attached to an interaction submission. Two submissions with the same key and the same payload are treated as one logical request; the same key with a **different payload** is rejected (Section 5.1). The web form generates one key when the form is opened and reuses it for retries of that same form instance.
- **Dev token** — a development-only credential presented as a request header. The system resolves a valid dev token to a specific seeded user and tenant. Credential *verification* is the only stubbed step; authentication, tenant-membership resolution, and authorization are real behavior and behave exactly as they will with production credentials.
- **Empty state** — the explicit UI presentation shown when a list has no items (not a blank screen and not an error).

---

## 2. Identity and sign-in behavior (dev-token stub)

Observable behavior, honoring the frozen decision that only credential verification is stubbed:

- **P-AUTH-1.** Every request to the CRM (UI-originated or direct API) must carry a dev token. The browser session obtains one by the user selecting/entering a seeded dev token; thereafter the app presents it on every request.
- **P-AUTH-2.** A request with no token, an unknown token, or a malformed token is rejected as **unauthenticated**. The UI shows a "sign in required" state and never partial data. Test: call any read or write without a token → authentication error; no record is created or returned.
- **P-AUTH-3.** A valid token resolves to exactly one user and one **active tenant**. All subsequent reads and writes carrying that token are scoped to that tenant. The UI displays both the acting user's identity (name) and the active tenant so a tester can confirm who they are acting as and where.
- **P-AUTH-3a.** A user may hold memberships in multiple tenants. With the dev-token stub, each seeded token binds the user to one active tenant; a user with two memberships is seeded with two tokens, one per tenant. Presenting token A shows only tenant A's companies, contacts, tasks, and audit events; presenting token B shows only tenant B's. Test: seed one user with memberships in tenants A and B; verify each token yields exactly its own tenant's data, with no record from the other tenant visible in any list, timeline, or audit view.
- **P-AUTH-3b.** The membership for the active tenant is independently verified on **every** request, not cached from sign-in. Test: after a successful request, **revoke** the user's membership in the active tenant in seed/fixture state; the next request with the same still-valid token is rejected as unauthorized with no side effects. Concurrent-revocation case: the database contract's in-transaction membership recheck (mechanism owned by Node D) guarantees the observable behavior that a revocation committed before a write's commit means the write is rejected with nothing created; the test may race a revocation against a submission and assert either clean success (revocation lost the race) or rejection with nothing created — never a write that survives a prior-committed revocation.
- **P-AUTH-4.** A token whose user has no membership (or only a revoked membership) in the request's active tenant is rejected as unauthorized before any record-level logic runs. Test: seed a user without membership; every read and write fails with an authorization error and no side effects.
- **P-AUTH-5.** The dev token mechanism is available only in development builds/environments. This is a deployment property; its observable form is that no production configuration documents or accepts the dev-token header. (Testable at the configuration level, not through the slice UI.)
- **P-AUTH-6 (suspended tenant).** A request whose active tenant is **suspended** is rejected as unauthorized before any record-level logic runs, even with a valid token and an unrevoked membership. No tenant data is returned and nothing is created. Test: seed a suspended tenant with a member user and token; every read and write is rejected; after the tenant is reactivated in fixture state, the same token works again.
- **P-AUTH-7 (deactivated user).** A token resolving to a **deactivated** user is rejected before any record-level logic runs, with no data and no side effects, regardless of memberships. Test: seed a deactivated user with an otherwise valid token and membership; every read and write is rejected; records previously created by that user remain visible to other members (deactivation hides nothing that already happened).
- **P-AUTH-8 (denial observability).** Every authentication or authorization denial (P-AUTH-2, 3b, 4, 6, 7 and Section 5.4/5.6 denials) is server-logged with: the actor claim (as presented), tenant (as requested, if resolvable), route, and timestamp. Token values are **never** written to logs. Test: trigger each denial class and assert a log entry with those fields exists and contains no token material. **Rate limiting is an explicit pre-exposure future requirement, not in this slice** (rationale: the only users are seeded internal ones; rate limiting must exist before any external exposure).

---

## 3. Screens

Six screens. Each lists what a tester must be able to observe.

### 3.1 Home — open next-action tasks
- Shows the list of the acting user's **open** next-action tasks within the current tenant, each displaying: the generated task title, contact name, company name, due date, and the outcome label of the interaction that created it.
- **Ordering is deterministic:** due date ascending (soonest first); ties broken by task creation date-time ascending (older first); remaining ties by task identifier ascending. Test: seed three tasks sharing a due date and two sharing a creation time; the rendered order matches this rule exactly on repeated loads.
- Done tasks do not appear.
- **Empty state:** when the user has no open tasks, the screen shows an explicit "no next actions due" message and a path to the companies screen. It is visually distinct from a loading or error state.

### 3.2 Companies screen (list + create)
Company listing and creation are folded into one dedicated screen (this is the ruling's "specify one" choice — a separate list screen, not a modal buried elsewhere):
- Shows all companies in the acting user's tenant. **Each list row shows:** company name and the count of its contacts.
- Rows are ordered by company name ascending (case-insensitive), ties by company identifier ascending.
- Provides the **create-company** action: a form with one required non-empty name field. Submitting a blank or whitespace-only name is a validation error (field-level message, nothing created). On success the new company appears in the list and an audit event for the creation appears in the audit view.
- Selecting a row opens that company's screen (3.3).
- **Empty state:** a tenant with no companies shows an explicit "no companies yet" message with the create-company action.

### 3.3 Company screen
- Shows the company's name and the list of its contacts (name, email and phone when present, last-contacted timestamp or "never contacted").
- Provides the action to create a new contact under this company. The create-contact form has: **required** non-empty name, **optional** email, **optional** phone. A blank name is a validation error (nothing created); omitting email and phone is valid.
- **Empty state:** a company with no contacts shows an explicit "no contacts yet" message with the create-contact action.

### 3.4 Contact screen with timeline
- Shows the contact's name, owning company, email and phone **when present** (absent optional fields are simply not rendered — no placeholder error), and last-contacted timestamp (or "never contacted").
- Shows the **timeline**: all interactions for this contact, newest first, each entry as defined in Section 1.
- Provides the action to open the log-interaction form for this contact.
- **Empty state:** a contact with no interactions shows an explicit "no interactions yet" message with the log-interaction action, and last-contacted shows "never contacted".
- Test (optional fields): create one contact with email and phone and one with neither; the first displays both values on this screen and the company screen; the second displays neither and no error.

### 3.5 Log-interaction form
- Reachable from a contact. Fields: interaction type (fixed to "call" in this slice), **outcome** (required; a selection from the closed seeded list — no free typing), note (optional free text), **next-action date** (required; a date on or after today, where "today" is the current date in the tenant's operating timezone as defined in Section 1).
- The form carries an idempotency key generated when the form instance is opened; retries of the same instance reuse it (invisible to the user except through the duplicate-submission behavior in Section 5.1).
- On success the user is returned to the contact screen and can immediately see the new timeline entry; a confirmation indicates the interaction was logged and a next-action task was created.
- Validation failures (Sections 5.2, 5.3) keep the user on the form with the entered values preserved and a field-level error message; nothing is created.

### 3.6 Audit view
- Shows a chronological list (newest first) of audit events within the acting user's tenant.
- Each row displays: actor, tenant, action, record (type and identifier sufficient for a tester to match it to the affected business record), and time.
- Creating a company, creating a contact, and logging an interaction each produce at least one audit event visible here. The interaction submission's audit trail must let a tester confirm that the interaction and its next-action task resulted from the same submission.
- **Empty state:** a tenant with no audited activity shows an explicit "no audit events" message.

---

## 4. The complete user journey

A tester must be able to perform this end-to-end through the web UI as a seeded salesperson:

1. **Sign in (dev token).** Present a seeded dev token. The UI shows the acting user's identity and active tenant. (P-AUTH-3.)
2. **Create a company.** On the companies screen, provide a name. The company appears in the list with a contact count of 0; an audit event for the creation appears in the audit view.
3. **Create a contact.** Under that company, provide a name (optionally email and phone). The contact appears on the company screen with "never contacted"; an audit event appears.
4. **Log a call with outcome and set a next-action date.** From the contact screen, open the log-interaction form; select an outcome, optionally add a note, set a next-action date on or after today (tenant timezone); submit.
5. **Observe synchronous results** — all visible immediately after the success confirmation, without waiting for any background processing:
   - The contact **timeline** shows exactly one new entry with the chosen outcome label, note, acting user, and logged time.
   - The contact's **last-contacted timestamp** now equals the logged time of this interaction.
   - **Home** shows exactly one new open next-action task for this contact with the chosen due date and the exact generated title for the chosen outcome (Section 1 title table).
   - The **audit view** shows the audit event(s) for this submission identifying actor, tenant, action, record, and time.
6. **Observe asynchronous results.** Within **30 seconds** (the CI assertion bound for the local environment), the processing state for this submission's outbox event reaches **processed** (Section 6.4). No additional task, timeline entry, or contact change appears as a result of background processing.

Journey invariant: one successful submission produces **exactly one** interaction, **exactly one** open next-action task, **exactly one** last-contacted update, exactly one processing receipt (eventually), and a complete audit trail — regardless of retries, duplicate deliveries, or worker restarts (Sections 5 and 6).

---

## 5. Edge cases as observable behavior

### 5.1 Duplicate form submission (same idempotency key)
- **Behavior:** if the same interaction submission is sent twice with the same idempotency key and the same payload (double-click, network retry, or a tester replaying the request), the second submission does not create anything new. The user experience of the second submission is success, referring to the same interaction and task as the first.
- **Test (sequential duplicate):** submit the same request twice with the same key. Verify: timeline has one new entry, home has one new task, both submissions' responses identify the same interaction and task IDs, and the audit view reflects one logical creation (a recorded duplicate-acknowledgment is permitted, but no second creation).
- **Request-hash mismatch:** the same idempotency key with a **different payload** is a client error: the request is rejected, **nothing is created**, and the original interaction and task are unchanged. Test: submit with key K and payload P1 (success), then key K and payload P2 → client error; re-read timeline, home, and audit view to confirm only the P1 records exist and are unmodified.
- **Simultaneous duplicate submission:** two concurrent requests with the same key and payload produce exactly one interaction and one task; **both** responses are successful and carry the **same** interaction and task IDs. Test: fire both requests concurrently (automated test harness), await both, assert ID equality across responses and the Section 4 invariant counts.
- **Contrast:** the same field values submitted with a **different** idempotency key are a new logical request and create a second interaction and task. (Deliberate: logging two identical calls in a day is legitimate.)

### 5.2 Invalid next-action date
- A missing next-action date, an unparseable date, or a date before today is rejected at validation. "Today" is evaluated as the current date in the tenant's required **operating timezone** (`Tenant.operating_timezone`, an IANA identifier — Section 1), not the server's or browser's timezone. The form shows a field-level error naming the next-action date; the entered values are preserved; **nothing is created** — no interaction, task, timeline entry, last-contacted change, audit business event, or outbox event.
- "Today" (in the tenant's operating timezone) is a valid next-action date.
- **Test:** submit with yesterday's date via UI and via direct API; verify the validation error and verify by re-reading the contact, home, and audit view that no state changed.
- **Timezone-boundary test (seeded zone, deterministic at any run time):** the fixture seeds a tenant with the fixed non-UTC IANA timezone `Pacific/Kiritimati` (UTC+14, no daylight saving) — seeded, not runtime-selected, per the human ruling. At test runtime, compute "tenant-local today" and "tenant-local yesterday" in that seeded zone. Assert: a submission dated tenant-local today is **accepted**, and a submission dated tenant-local yesterday is **rejected** — both assertions hold at every hour of every day because the dates are computed in the seeded zone at runtime; no assertion may depend on the seeded zone's date differing from the server's local date at the moment the test runs.

### 5.3 Invalid or missing outcome
- A missing outcome, or an outcome value not in the seeded closed list of stored tokens (Section 1), is rejected at validation with a field-level error naming the outcome, values preserved, nothing created (same "nothing created" assertions as 5.2). The UI makes this hard to trigger (selection control), so the direct-API test is the primary check.

### 5.4 Cross-tenant access attempt
- **Decision: cross-tenant reads and writes are indistinguishable from not-found in their public response.** A user in tenant A who requests, mutates, or logs an interaction against a record ID belonging to tenant B receives the **same public HTTP status and the same public error body shape and content** as for an ID that does not exist at all.
- **Scope of the guarantee:** the contract guarantees identical status and body only. Timing side-channel guarantees (deterministic or equivalent response timing) are explicitly **out of scope** for this slice and are not promised.
- **Why not-found rather than explicit forbidden:** an explicit "forbidden" confirms that the record exists in some other tenant, leaking record existence and enabling ID enumeration across tenants. Not-found leaks nothing, which matches the charter invariant that every record is tenant-scoped and matches the acceptance criterion that unauthorized users "cannot read or mutate" another tenant's contact.
- **Test:** seed two tenants each with a user and a contact. As tenant A's user: (a) read tenant B's contact by ID, (b) submit an interaction against it, (c) read a random nonexistent ID. Assert (a) and (b) return the same HTTP status and the same error body as (c) (identical after substituting the requested ID, if the body echoes it), and that (b) created nothing in either tenant (check both tenants' timelines, tasks, and audit views). Do not assert on response timing.
- Cross-tenant attempts also never appear in tenant B's audit view (nothing happened in tenant B). They are server-logged as denials per P-AUTH-8.

### 5.5 Empty states
- Each empty state in Section 3 is an explicit, testable presentation: a fresh seeded tenant shows the home empty state, companies-screen empty state, and audit-view empty state; a new company shows the no-contacts state; a new contact shows the no-interactions state and "never contacted".

### 5.6 Unauthenticated request
- Covered by P-AUTH-2/P-AUTH-4/P-AUTH-6/P-AUTH-7: any read or write without a valid token, without an unrevoked membership, within a suspended tenant, or by a deactivated user fails before business logic, returns no tenant data, and creates nothing. Such attempts do not appear in any tenant's audit view; they are server-logged per P-AUTH-8.

### 5.7 Referential edge cases within the slice
- Creating a contact requires an existing company in the same tenant; a company reference that fails the tenant-scoped lookup behaves per 5.4 (not-found).
- Logging an interaction requires an existing contact in the same tenant; otherwise 5.4 applies.

---

## 6. Asynchronous behavior as observable outcomes

The observable contract for the asynchronous path—from a committed Outbox event through publication and processing—is:

- **6.1 No synchronous dependency.** All Section 4 step-5 results are visible even if the background worker is stopped. A tester can stop the worker, complete the journey through the timeline/task/audit checks, and see everything except the "processed" state.
- **6.2 Duplicate event delivery is invisible.** If the same event is delivered or processed more than once, the outcome is: **exactly one processing receipt for that event**, and no duplicate downstream record — task count, timeline-entry count, and contact state are unchanged from before the redelivery. Test: force redelivery of a processed event (mechanism owned by the integration test), then assert receipt count is exactly one for that event and re-assert the Section 4 invariant counts.
- **6.3 Worker restart loses nothing.** Kill the worker after a submission but before processing; restart it; the event is processed and its processing state reaches "processed" (within the Section 4 bound of 30 seconds after restart) with all Section 6.2 invariants intact. No user action is required to recover.
- **6.4 Inspectable processing state.** For every interaction submission, an inspection surface (presentation owned by Node A) reports which of these **four** operator-facing states the resulting outbox event is in. State precedence is exact:
  1. **processed** — the required consumer processing receipt has status processed.
  2. **failed** — outbox publication or consumer processing is failed.
  3. **published** — publication to the event stream was acknowledged and no processed/failed state takes precedence.
  4. **pending** — otherwise, including while an active publication lease is held.

  For failed events the surface exposes **failure_stage** (`publication` | `consumer`) and the last error. The state must be joinable to the originating interaction so the full path is inspectable end to end.

  **Security of the inspection surface:** it uses the same authentication, active-tenant Membership resolution, authorization, tenant scoping, and cross-tenant not-found behavior (Section 5.4) as every other endpoint. Test: tenant A's user querying processing state for tenant B's interaction gets the identical not-found status and body as for a nonexistent interaction; unauthenticated queries are rejected per P-AUTH-2.
- **6.5 The consumer's side effect is the processing receipt.** In Sprint 0001, the consumer's only side effect **is the processing receipt itself**. The consumer does not create a Task, does not modify the Contact, does not send a notification, and does not call any external system. The receipt is the processing-state record of the Outbox event, not a tenth business object. Background processing therefore produces no email, no notification, and no external call; its only effects are the receipt and the processing state.
- **6.6 QA carve-out (explicit exception to the "no internal access" preamble).** Until the Node A inspection surface exists, automated integration tests may make processing-state assertions (pending/published/processed/failed, failure_stage, receipt counts) and "nothing created — including no outbox event" assertions **at the database level**. Once the inspection surface ships, processing-state assertions move to it; database-level assertions remain acceptable for outbox-absence checks that the public surface intentionally does not expose.

---

## 7. Acceptance criteria mapped 1:1 to observable behavior

Each criterion from `docs/FIRST_VERTICAL_SLICE.md` with the exact behavior a tester performs under this contract's product language. Source wording is preserved (including its "follow-up" term, mapped to next-action per the preamble) except that the source's vendor-specific event-technology wording is rendered in product terms ("the event stream"), per the human ruling that vendor names must not appear in this contract; AC-4 below cites its source criterion by position rather than quoting it.

| # | Source acceptance criterion / product rendering | Observable behavior / tester procedure |
|---|---|---|
| AC-1 | A user can complete the journey from the web interface. | Perform Section 4 steps 1–6 entirely in the browser as a seeded user; every listed observation succeeds. |
| AC-2 | Unauthorized users cannot read or mutate another tenant's contact. | Section 5.4 test: cross-tenant read and write return the same public HTTP status and error body as a nonexistent record (no timing assertions); nothing is created in either tenant. Plus P-AUTH-2/3a/3b/4/6/7: no token, wrong active tenant, revoked membership, suspended tenant, or deactivated user → rejected with no data and no side effects. |
| AC-3 | A duplicate HTTP request with the same idempotency key produces one interaction and one task. | Section 5.1 tests: (i) sequential duplicate — two submissions, same key and payload → one timeline entry, one open task, both responses reference the same interaction and task IDs; (ii) simultaneous duplicate — two concurrent same-key requests → same single-creation result, both responses carry the same IDs; (iii) request-hash mismatch — same key, different payload → client error, nothing created, originals unchanged. All three are automated tests. |
| AC-4 | A duplicate event delivered from the event stream produces no duplicate business side effect (paraphrase of the fourth acceptance criterion in `docs/FIRST_VERTICAL_SLICE.md`). | Section 6.2 test: force redelivery of a processed event; assert **exactly one processing receipt exists for that event**, and no duplicate downstream record — task, timeline-entry, and contact-state counts are unchanged after redelivery. |
| AC-5 | Killing and restarting the worker does not lose the event. | Section 6.3 test: stop worker → submit → verify state is pending/published but not processed → restart worker → state reaches processed within 30 seconds; invariant counts unchanged. |
| AC-6 | The contact timeline shows the interaction. | Section 4 step 5: immediately after submission, the contact screen shows one new timeline entry with outcome label, note, acting user, and logged time. |
| AC-7 | Home shows the open follow-up task. | Section 4 step 5 (product term: next-action task): home lists exactly one new open task for the contact with the chosen due date and the exact generated title for the outcome; ordering follows the Section 3.1 deterministic rule; done tasks (if seeded) do not appear. Marking-done behavior is out of scope. |
| AC-8 | The audit view identifies actor, tenant, action, record, and time. | Section 3.6: open the audit view after the journey; for company creation, contact creation, and the interaction submission, each audit row shows all five fields and the record field matches the created record. |
| AC-9 | Automated tests prove the above. | Every behavior in this document is stated as a procedure with an assertable outcome; the implementation nodes must encode AC-1 through AC-8 and Sections 5.1 (all three cases), 5.2 (including the seeded-timezone boundary test), 5.3, 5.5, 5.6, P-AUTH-6/7/8, and 6.4's security test as automated tests, using the Section 6.6 carve-out where the inspection surface does not yet exist. A criterion is not met until its automated test passes. |

The synchronous ordering in FIRST_VERTICAL_SLICE.md (authenticate → resolve membership → authorize → validate → transact → return IDs) is testable as: an unauthenticated or non-member request never returns a validation error (auth precedes validation, per 5.6), and a validation failure never creates any record (validation precedes the transaction, per 5.2/5.3). The "return the interaction and task IDs" step is testable via AC-3: duplicate responses carry the same two IDs.

---

## 8. Non-goals for this slice

Observable behaviors explicitly **not** in this slice; their absence is not a defect:

- **No custom objects.** Only the nine required objects exist; there is no UI or API to define new record types or fields.
- **No email or calendar capture.** No interaction is created from email or calendar data; the only way an interaction exists is the log-interaction form/API.
- **No reporting.** No dashboards, pipeline analytics, aggregates, or exports. Home is a task list, not a report.
- **No task lifecycle beyond open.** Completing, editing, reassigning, or snoozing tasks is out of scope; tasks are created open and stay open in this slice. (Consequence, per the outcome ruling: closing out a `not_interested` relationship is performed outside the system in this slice; the generated review task records the obligation.)
- **No editing or deleting** of companies, contacts, or interactions after creation.
- **No interaction types other than call**, and no channels (email, meeting, SMS).
- **No rate limiting.** Explicit pre-exposure future requirement (P-AUTH-8): must exist before any external tenant or public exposure; unnecessary while all users are seeded internal users.
- **No consumer-side business writes.** The consumer's side effect is the processing receipt only (Section 6.5); downstream projections (search, reminders, analytics) are future stages behind the same event contract.
- **No search** beyond navigating lists; no notifications or reminder emails (see 6.5); no user self-registration, password auth, or tenant administration UI (identity, tenant status, and user status are seeded; dev-token only); no mobile-native app.

---

## 9. Self-verification against the sprint checklist and Wave-1 rulings

- Every FIRST_VERTICAL_SLICE acceptance criterion appears in Section 7 with a tester-performable behavior: yes (AC-1..AC-9; source meaning preserved, with vendor-specific infrastructure wording rendered in product language).
- Ruling A: `not_interested` token kept with label "Not interested now" (Section 1); product-wide rename to next-action task/date applied throughout with a terminology note in the preamble; the one-task-per-interaction invariant is restated for every outcome; deterministic generated task titles are defined for all five tokens, including the mandated exact `not_interested` title (Section 1 title table), and asserted in Section 4 step 5 / AC-7.
- Consumer side effect: Section 6.5 states the processing receipt **is** the consumer's entire side effect (no Task, no Contact change, no notification, no external call); the receipt is defined in Section 1 as the Outbox event's processing-state record, not a tenth business object. AC-4 rewritten to assert exactly one receipt plus unchanged downstream counts.
- Processing states: Section 6.4 defines four operator-facing states with the exact mandated precedence (processed → failed → published → pending, including the active-publication-lease case) and exposes failure_stage (publication | consumer) and last error.
- Inspection-surface security: Section 6.4 requires the same authentication, active-tenant membership resolution, authorization, tenant scoping, and cross-tenant not-found behavior as all other endpoints, with a test.
- Minor findings: contact optional email/phone with display-when-present behavior and test (Sections 1, 3.3, 3.4); companies screen chosen as a dedicated sixth screen with specified row contents, ordering, and create behavior (Section 3.2); deterministic home ordering with secondary (creation time asc) and tertiary (task ID asc) keys and a test (Section 3.1); "revoke membership" used everywhere — no "remove" wording remains (Sections 1, 2); suspended-tenant and deactivated-user rules adopted as P-AUTH-6/7 with tester procedures; timezone-boundary test uses the seeded non-UTC zone `Pacific/Kiritimati` with runtime-computed tenant-local today/yesterday assertions valid at any run time (Section 5.2); request-hash mismatch and simultaneous duplicate submission specified and mapped to automated tests (Sections 5.1, 7 AC-3); the async bound is a concrete 30 seconds stated as the CI assertion bound (Sections 4, 6.3, 7 AC-5); the contract uses product-level event language only ("the event stream", "publication", "event processing"); per the superseding human ruling, the vendor name of the event technology appears nowhere in this file — a case-insensitive search of this document for that vendor name returns zero matches, with AC-4 paraphrased and cited by position instead of quoted; the QA database-level carve-out is explicit (Section 6.6) and reconciled with the preamble; denial logging (actor claim, tenant, route, timestamp; never token values) and the rate-limiting future requirement are recorded (P-AUTH-8, Section 8).
- P-AUTH-3b now covers the concurrent-revocation case via the database contract's in-transaction membership recheck, with mechanism ownership left to Node D and only observable behavior specified here.
- No behavior requires objects beyond Tenant, User, Membership, Company, Contact, Interaction, Task, Audit event, Outbox event: verified — outcome vocabulary, generated task titles, operating timezone, tenant/user statuses, active tenant, idempotency key, timeline, processing state, processing receipt, publication lease, and empty states are attributes or presentations of those nine objects, not new object types.
- Every newly introduced noun is defined in Section 1.
- No API shapes, no schema/DDL, no infrastructure choices are made here beyond restating frozen decisions, human rulings, and charter invariants.
