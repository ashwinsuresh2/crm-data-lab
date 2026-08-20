# Product Behavior Contract — First Vertical Slice

Status: Draft for Sprint 0001 integration
Owner: Node P (Product behavior)
Scope source: `docs/FIRST_VERTICAL_SLICE.md`, `docs/PROJECT_CHARTER.md`

This document defines the observable behavior of the first vertical slice. It describes what a salesperson (and a tester) can see and do. It does not define API endpoint shapes (Node A), the domain model (Node D), or infrastructure. Every behavior below must be verifiable through the web UI or the CRM API by a tester with no access to internal implementation.

---

## 1. Definitions

Every noun used in this contract is defined here. No behavior in this document requires objects beyond: Tenant, User, Membership, Company, Contact, Interaction, Task, Audit event, Outbox event.

- **Tenant** — the isolation boundary that owns all business records. Every company, contact, interaction, task, audit event, and outbox event belongs to exactly one tenant. Every tenant has a required **operating timezone**.
- **Operating timezone (`Tenant.operating_timezone`)** — a required tenant property holding an IANA timezone identifier (for example `America/Los_Angeles`). It defines what "today" means for that tenant: follow-up-date validation ("today or later", Section 5.2) is evaluated against the current date in the tenant's operating timezone, not the server's or the browser's timezone.
- **User** — an identity that can act in the system. A user may hold memberships in multiple tenants, but every request carries exactly one **active tenant** context, and the user acts only within that tenant for that request.
- **Membership** — the association between a user and a tenant that grants the user the right to act inside that tenant. A user may have zero, one, or many memberships. The membership for the request's active tenant is independently verified on every request; a user with no membership in the active tenant has no access to any of that tenant's records, regardless of memberships elsewhere.
- **Active tenant** — the single tenant context attached to a request. With the dev-token stub, each seeded dev token binds one user to one active tenant (Section 2); switching tenants means presenting a different token.
- **Company** — a business record representing an organization the salesperson sells to. Minimum user-visible attribute: a required non-empty name.
- **Contact** — a business record representing a person, associated with exactly one company in the same tenant. Minimum user-visible attributes: a required non-empty name and the owning company. A contact also displays a **last-contacted timestamp**: the date-time of the most recent interaction logged against that contact, or an explicit "never contacted" state if none exists.
- **Interaction** — a record of a communication with a contact. In this slice the only interaction type is a **call**. An interaction has: the contact it belongs to, a required **outcome**, an optional free-text note, a required **follow-up date**, the acting user, and the date-time it was logged.
- **Outcome** — a required classification of the call chosen from the closed, seeded list defined below. This vocabulary is a product decision owned by this contract. The stored token is the exact value accepted by the API; the user-visible label is the exact text rendered in the form and on timeline entries. Free-typed outcome values are not accepted, and no other values are valid in this slice.

  | Stored token | User-visible label | Meaning |
  |---|---|---|
  | `connected` | Connected | Spoke with the contact. |
  | `no_answer` | No answer | Call placed; no one answered and no message was left. |
  | `left_voicemail` | Left voicemail | Call placed; a voicemail was left. |
  | `meeting_scheduled` | Meeting scheduled | Spoke with the contact and a meeting was agreed. |
  | `not_interested` | Not interested | Spoke with the contact; they declined further engagement. |

  The form presents exactly these five labels, in this order, as a selection control.
- **Task** — a follow-up work item created as a consequence of logging an interaction. A task has: the contact it relates to, the interaction that caused it, a due date (the follow-up date), a status of **open** or **done**, and the user it is assigned to (in this slice, the acting user). "Open follow-up task" means a task whose status is open.
- **Timeline** — the chronological list of interactions for a contact, newest first, shown on the contact screen. A **timeline entry** displays: interaction type (call), outcome, note (if any), acting user, and logged date-time.
- **Audit event** — an immutable record of a meaningful write, visible in the audit view. Each audit event identifies: **actor** (the user), **tenant**, **action** (what kind of change), **record** (which business record was affected), and **time**.
- **Outbox event** — a durable event appended in the same transaction as the write it describes, later published to Kafka. Its only *user-visible* manifestation in this slice is the inspectable **processing state** (Section 6.4); its wire format is out of scope here.
- **Idempotency key** — a client-supplied opaque token attached to an interaction submission. Two submissions with the same key are treated as one logical request. The web form generates one key when the form is opened and reuses it for retries of that same form instance.
- **Dev token** — a development-only credential presented as a request header. The system resolves a valid dev token to a specific seeded user and tenant. Credential *verification* is the only stubbed step; authentication, tenant-membership resolution, and authorization are real behavior and behave exactly as they will with production credentials.
- **Empty state** — the explicit UI presentation shown when a list has no items (not a blank screen and not an error).

---

## 2. Identity and sign-in behavior (dev-token stub)

Observable behavior, honoring the frozen decision that only credential verification is stubbed:

- **P-AUTH-1.** Every request to the CRM (UI-originated or direct API) must carry a dev token. The browser session obtains one by the user selecting/entering a seeded dev token; thereafter the app presents it on every request.
- **P-AUTH-2.** A request with no token, an unknown token, or a malformed token is rejected as **unauthenticated**. The UI shows a "sign in required" state and never partial data. Test: call any read or write without a token → authentication error; no record is created or returned.
- **P-AUTH-3.** A valid token resolves to exactly one user and one **active tenant**. All subsequent reads and writes carrying that token are scoped to that tenant. The UI displays both the acting user's identity (name) and the active tenant so a tester can confirm who they are acting as and where.
- **P-AUTH-3a.** A user may hold memberships in multiple tenants. With the dev-token stub, each seeded token binds the user to one active tenant; a user with two memberships is seeded with two tokens, one per tenant. Presenting token A shows only tenant A's companies, contacts, tasks, and audit events; presenting token B shows only tenant B's. Test: seed one user with memberships in tenants A and B; verify each token yields exactly its own tenant's data, with no record from the other tenant visible in any list, timeline, or audit view.
- **P-AUTH-3b.** The membership for the active tenant is independently verified on **every** request, not cached from sign-in. Test: after a successful request, remove the user's membership in the active tenant in seed/fixture state; the next request with the same still-valid token is rejected as unauthorized with no side effects.
- **P-AUTH-4.** A token whose user has **no membership** in the request's active tenant is rejected as unauthorized before any record-level logic runs. Test: seed a user without membership; every read and write fails with an authorization error and no side effects.
- **P-AUTH-5.** The dev token mechanism is available only in development builds/environments. This is a deployment property; its observable form is that no production configuration documents or accepts the dev-token header. (Testable at the configuration level, not through the slice UI.)

---

## 3. Screens

Five screens. Each lists what a tester must be able to observe.

### 3.1 Home — open follow-up tasks
- Shows the list of the acting user's **open** follow-up tasks within the current tenant, each displaying: contact name, company name, due date, and the outcome of the interaction that created it.
- Tasks are ordered by due date ascending (soonest first).
- Done tasks do not appear.
- **Empty state:** when the user has no open tasks, the screen shows an explicit "no open follow-ups" message and a path to create a company or contact. It is visually distinct from a loading or error state.

### 3.2 Company screen
- Shows the company's name and the list of its contacts (name, last-contacted timestamp or "never contacted").
- Provides the action to create a new contact under this company.
- **Empty state:** a company with no contacts shows an explicit "no contacts yet" message with the create-contact action.
- The company list (however the tester navigates to it) shows only companies in the acting user's tenant, and shows an explicit empty state when the tenant has no companies.

### 3.3 Contact screen with timeline
- Shows the contact's name, owning company, and last-contacted timestamp (or "never contacted").
- Shows the **timeline**: all interactions for this contact, newest first, each entry as defined in Section 1.
- Provides the action to open the log-interaction form for this contact.
- **Empty state:** a contact with no interactions shows an explicit "no interactions yet" message with the log-interaction action, and last-contacted shows "never contacted".

### 3.4 Log-interaction form
- Reachable from a contact. Fields: interaction type (fixed to "call" in this slice), **outcome** (required; a selection from the closed seeded list — no free typing), note (optional free text), **follow-up date** (required; a date on or after today, where "today" is the current date in the tenant's operating timezone as defined in Section 1).
- The form carries an idempotency key generated when the form instance is opened; retries of the same instance reuse it (invisible to the user except through the duplicate-submission behavior in Section 5.1).
- On success the user is returned to the contact screen and can immediately see the new timeline entry; a confirmation indicates the interaction was logged and a follow-up task was created.
- Validation failures (Sections 5.2, 5.3) keep the user on the form with the entered values preserved and a field-level error message; nothing is created.

### 3.5 Audit view
- Shows a chronological list (newest first) of audit events within the acting user's tenant.
- Each row displays: actor, tenant, action, record (type and identifier sufficient for a tester to match it to the affected business record), and time.
- Creating a company, creating a contact, and logging an interaction each produce at least one audit event visible here. The interaction submission's audit trail must let a tester confirm that the interaction and its follow-up task resulted from the same submission.
- **Empty state:** a tenant with no audited activity shows an explicit "no audit events" message.

---

## 4. The complete user journey

A tester must be able to perform this end-to-end through the web UI as a seeded salesperson:

1. **Sign in (dev token).** Present a seeded dev token. The UI shows the acting user's identity. (P-AUTH-3.)
2. **Create a company.** Provide a name. The company appears in the tenant's company list; an audit event for the creation appears in the audit view.
3. **Create a contact.** Under that company, provide a name. The contact appears on the company screen with "never contacted"; an audit event appears.
4. **Log a call with outcome and schedule a follow-up.** From the contact screen, open the log-interaction form; select an outcome, optionally add a note, set a follow-up date on or after today; submit.
5. **Observe synchronous results** — all visible immediately after the success confirmation, without waiting for any background processing:
   - The contact **timeline** shows exactly one new entry with the chosen outcome, note, acting user, and logged time.
   - The contact's **last-contacted timestamp** now equals the logged time of this interaction.
   - **Home** shows exactly one new open follow-up task for this contact with the chosen due date.
   - The **audit view** shows the audit event(s) for this submission identifying actor, tenant, action, record, and time.
6. **Observe asynchronous results.** Within a bounded time (test budget: tens of seconds, not hours), the processing state for this submission's outbox event reaches "processed" (Section 6.4). No additional task, timeline entry, or contact change appears as a result of background processing.

Journey invariant: one successful submission produces **exactly one** interaction, **exactly one** open task, **exactly one** last-contacted update, and a complete audit trail — regardless of retries, duplicate deliveries, or worker restarts (Sections 5 and 6).

---

## 5. Edge cases as observable behavior

### 5.1 Duplicate form submission (same idempotency key)
- **Behavior:** if the same interaction submission is sent twice with the same idempotency key (double-click, network retry, or a tester replaying the request), the second submission does not create anything new. The user experience of the second submission is success, referring to the same interaction and task as the first.
- **Test:** submit the same request twice with the same key. Verify: timeline has one new entry, home has one new task, both submissions' responses identify the same interaction and task, and the audit view reflects one logical creation (a recorded duplicate-acknowledgment is permitted, but no second creation).
- **Contrast:** the same field values submitted with a **different** idempotency key are a new logical request and create a second interaction and task. (Deliberate: logging two identical calls in a day is legitimate.)

### 5.2 Invalid follow-up date
- Missing follow-up date, an unparseable date, or a date before today is rejected at validation. "Today" is evaluated as the current date in the tenant's required **operating timezone** (`Tenant.operating_timezone`, an IANA identifier — Section 1), not the server's or browser's timezone. The form shows a field-level error naming the follow-up date; the entered values are preserved; **nothing is created** — no interaction, task, timeline entry, last-contacted change, audit business event, or outbox event.
- "Today" (in the tenant's operating timezone) is a valid follow-up date.
- **Test:** submit with yesterday's date via UI and via direct API; verify the validation error and verify by re-reading the contact, home, and audit view that no state changed. Timezone boundary test: with a tenant whose operating timezone differs from the server clock's zone such that the local dates differ at test time, verify that a follow-up date equal to the tenant-local "today" is accepted even when it is "yesterday" or "tomorrow" in server time.

### 5.3 Invalid or missing outcome
- A missing outcome, or an outcome value not in the seeded closed list, is rejected at validation with a field-level error naming the outcome, values preserved, nothing created (same "nothing created" assertions as 5.2). The UI makes this hard to trigger (selection control), so the direct-API test is the primary check.

### 5.4 Cross-tenant access attempt
- **Decision: cross-tenant reads and writes are indistinguishable from not-found in their public response.** A user in tenant A who requests, mutates, or logs an interaction against a record ID belonging to tenant B receives the **same public HTTP status and the same public error body shape and content** as for an ID that does not exist at all.
- **Scope of the guarantee:** the contract guarantees identical status and body only. Timing side-channel guarantees (deterministic or equivalent response timing) are explicitly **out of scope** for this slice and are not promised.
- **Why not-found rather than explicit forbidden:** an explicit "forbidden" confirms that the record exists in some other tenant, leaking record existence and enabling ID enumeration across tenants. Not-found leaks nothing, which matches the charter invariant that every record is tenant-scoped and matches the acceptance criterion that unauthorized users "cannot read or mutate" another tenant's contact.
- **Test:** seed two tenants each with a user and a contact. As tenant A's user: (a) read tenant B's contact by ID, (b) submit an interaction against it, (c) read a random nonexistent ID. Assert (a) and (b) return the same HTTP status and the same error body as (c) (identical after substituting the requested ID, if the body echoes it), and that (b) created nothing in either tenant (check both tenants' timelines, tasks, and audit views). Do not assert on response timing.
- Cross-tenant attempts also never appear in tenant B's audit view (nothing happened in tenant B).

### 5.5 Empty states
- Each empty state in Section 3 is an explicit, testable presentation: a fresh seeded tenant shows the home empty state, company-list empty state, and audit-view empty state; a new company shows the no-contacts state; a new contact shows the no-interactions state and "never contacted".

### 5.6 Unauthenticated request
- Covered by P-AUTH-2/P-AUTH-4: any read or write without a valid token (or without membership) fails before business logic, returns no tenant data, and creates nothing. Unauthenticated write attempts do not appear in any tenant's audit view.

### 5.7 Referential edge cases within the slice
- Creating a contact requires an existing company in the same tenant; a company reference that fails the tenant-scoped lookup behaves per 5.4 (not-found).
- Logging an interaction requires an existing contact in the same tenant; otherwise 5.4 applies.

---

## 6. Asynchronous behavior as observable outcomes

The user-visible contract for the background path (Kafka publish and consumption):

- **6.1 No synchronous dependency.** All Section 4 step-5 results are visible even if the background worker is stopped. A tester can stop the worker, complete the journey through the timeline/task/audit checks, and see everything except the "processed" state.
- **6.2 Duplicate event delivery is invisible.** If the same event is delivered or processed more than once, the tester observes no second task, no duplicate timeline entry, no repeated last-contacted change, and no duplicated downstream record. Test: force redelivery (mechanism owned by the integration test), then re-assert the Section 4 invariant counts.
- **6.3 Worker restart loses nothing.** Kill the worker after a submission but before processing; restart it; the event is processed and its processing state reaches "processed" with all Section 6.2 invariants intact. No user action is required to recover.
- **6.4 Inspectable processing state.** For every interaction submission, a tester (via an operator-facing view or query surface — presentation owned by Node A) can determine which of these states the resulting outbox event is in: **pending** (recorded, not yet published), **published** (handed to Kafka), **processed** (consumer completed). The state must be joinable to the originating interaction so the full path is inspectable end to end.
- **6.5 No external side effects.** In this slice, background processing produces no email, no notification, and no call to any external system. Its only effects are internal records and the processing state.

---

## 7. Acceptance criteria mapped 1:1 to observable behavior

Each criterion from `docs/FIRST_VERTICAL_SLICE.md` with the exact behavior a tester performs.

| # | Acceptance criterion (verbatim) | Observable behavior / tester procedure |
|---|---|---|
| AC-1 | A user can complete the journey from the web interface. | Perform Section 4 steps 1–6 entirely in the browser as a seeded user; every listed observation succeeds. |
| AC-2 | Unauthorized users cannot read or mutate another tenant's contact. | Section 5.4 test: cross-tenant read and write return the same public HTTP status and error body as a nonexistent record (no timing assertions); nothing is created in either tenant. Plus P-AUTH-2/3a/3b/4: no token, wrong active tenant, or no membership → rejected with no data and no side effects. |
| AC-3 | A duplicate HTTP request with the same idempotency key produces one interaction and one task. | Section 5.1 test: two submissions, same key → one timeline entry, one open task, both responses reference the same interaction and task IDs. |
| AC-4 | A duplicate Kafka event produces no duplicate business side effect. | Section 6.2 test: force redelivery of a processed event; re-count tasks, timeline entries, and downstream records — counts unchanged. |
| AC-5 | Killing and restarting the worker does not lose the event. | Section 6.3 test: stop worker → submit → verify state is pending/published but not processed → restart worker → state reaches processed; invariant counts unchanged. |
| AC-6 | The contact timeline shows the interaction. | Section 4 step 5: immediately after submission, the contact screen shows one new timeline entry with outcome, note, acting user, and logged time. |
| AC-7 | Home shows the open follow-up task. | Section 4 step 5: home lists exactly one new open task for the contact with the chosen due date; marking-done behavior is out of scope, but done tasks (if seeded) do not appear. |
| AC-8 | The audit view identifies actor, tenant, action, record, and time. | Section 3.5: open the audit view after the journey; for company creation, contact creation, and the interaction submission, each audit row shows all five fields and the record field matches the created record. |
| AC-9 | Automated tests prove the above. | Every behavior in this document is stated as a procedure with an assertable outcome; the implementation nodes must encode AC-1 through AC-8 (and Sections 5.2, 5.3, 5.5, 5.6) as automated tests. A criterion is not met until its automated test passes. |

The synchronous ordering in FIRST_VERTICAL_SLICE.md (authenticate → resolve membership → authorize → validate → transact → return IDs) is testable as: an unauthenticated or non-member request never returns a validation error (auth precedes validation, per 5.6), and a validation failure never creates any record (validation precedes the transaction, per 5.2/5.3). The "return the interaction and task IDs" step is testable via AC-3: both duplicate responses carry the same two IDs.

---

## 8. Non-goals for this slice

Observable behaviors explicitly **not** in this slice; their absence is not a defect:

- **No custom objects.** Only the nine required objects exist; there is no UI or API to define new record types or fields.
- **No email or calendar capture.** No interaction is created from email or calendar data; the only way an interaction exists is the log-interaction form/API.
- **No reporting.** No dashboards, pipeline analytics, aggregates, or exports. Home is a task list, not a report.
- **No task lifecycle beyond open.** Completing, editing, reassigning, or snoozing tasks is out of scope; tasks are created open and stay open in this slice.
- **No editing or deleting** of companies, contacts, or interactions after creation.
- **No interaction types other than call**, and no channels (email, meeting, SMS).
- **No search** beyond navigating lists; no notifications or reminder emails (see 6.5); no user self-registration, password auth, or tenant administration UI (identity is seeded; dev-token only); no mobile-native app.

---

## 9. Self-verification against the sprint checklist

- Every FIRST_VERTICAL_SLICE acceptance criterion appears in Section 7 with a tester-performable behavior: yes (AC-1..AC-9).
- Dev-token auth flow described as user-visible behavior with only credential verification stubbed: Section 2, including multi-tenant membership behavior (P-AUTH-3a) and per-request membership verification (P-AUTH-3b).
- The outcome vocabulary is defined in this contract (Section 1: five stored tokens with user-visible labels) and is not delegated to any other node.
- `Tenant.operating_timezone` is defined as a required product property (IANA identifier, Section 1) and is the basis for follow-up-date validation (Section 5.2).
- Cross-tenant access guarantees are limited to identical public HTTP status and error body versus nonexistent records (Section 5.4); timing side-channel equivalence is explicitly out of scope and not promised.
- No behavior requires objects beyond Tenant, User, Membership, Company, Contact, Interaction, Task, Audit event, Outbox event: verified — the outcome vocabulary, operating timezone, active tenant, idempotency key, timeline, processing state, and empty states are attributes or presentations of those nine objects, not new object types.
- Every newly introduced noun is defined in Section 1.
- No API shapes, no schema/DDL, no infrastructure choices are made here beyond restating frozen decisions and charter invariants.
