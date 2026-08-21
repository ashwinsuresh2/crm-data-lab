# UX Information Architecture — First Vertical Slice

Status: Sprint 0001, Wave 2, Node U
Owner: Node U (UX architecture)
Upstream (frozen, immutable): `docs/specs/product-behavior.md` (P — primary), `docs/specs/WAVE1_FREEZE.md`, `docs/specs/local-topology.md` (dev context only), `docs/FIRST_VERTICAL_SLICE.md`, `CLAUDE.md`
Downstream: the Sprint 0002 React/Next.js web application (`apps/web`)

This document defines the information architecture, navigation, screen states, and interaction flows for the slice web app. It is documentation only: no components, no code, no visual design system, no endpoint shapes. Everywhere a screen needs data or an error shape, the source of truth is Node A's API contract; those points are marked **[Node A seam]**. All user-visible behavior restated here is P's; exact labels, titles, orderings, and empty-state messages are quoted verbatim from P and must not be paraphrased in implementation.

Two internal fields are named here only to ban them: **`seq` and `claim_id` (and any other internal outbox/lease fields) must never be rendered, logged to the browser console, or embedded in URLs by the web app.** The UI consumes only the operator-facing processing states and fields defined in P §6.4.

---

## 1. Global architecture

### 1.1 Route map

| # | Screen (P §3) | Route | Purpose |
|---|---|---|---|
| — | Sign-in gate (dev token) | `/sign-in` | Enter/select a seeded dev token (P §2). Not one of P's six screens; it is the P-AUTH-1 entry mechanism. |
| 1 | Home — open next-action tasks | `/` | The acting user's open next-action tasks (P §3.1). |
| 2 | Companies (list + create) | `/companies` | All companies in the tenant + create-company form (P §3.2). |
| 3 | Company | `/companies/{companyId}` | One company, its contacts, create-contact form (P §3.3). |
| 4 | Contact (with timeline) | `/contacts/{contactId}` | Contact details, timeline, log-interaction entry point (P §3.4). |
| 5 | Log-interaction form | `/contacts/{contactId}/log-interaction` | Log a call for this contact (P §3.5). |
| 6 | Audit view | `/audit` | Tenant audit events, newest first (P §3.6). |

Route parameters are opaque record identifiers as issued by the API **[Node A seam: identifier format]**. The log-interaction form is a dedicated route (not a modal) so that "form instance" has a crisp boundary: one idempotency key is generated per navigation into this route (P §1, §3.5) and survives retries within that instance; leaving the route and returning creates a new instance and a new key.

### 1.2 Navigation structure

- **Persistent app header** on every authenticated screen, containing:
  - Global navigation: Home (`/`), Companies (`/companies`), Audit (`/audit`).
  - **Identity block (always visible, P-AUTH-3):** the acting user's name and the active tenant name, so a tester can always confirm who they are acting as and where. This block is never hidden at any viewport size.
  - A sign-out action that discards the presented token and returns to `/sign-in`. Switching tenants = signing out and presenting a different seeded token (P §1 "Active tenant", P-AUTH-3a). There is no in-app tenant switcher in this slice.
- **Contextual drill-down:** Companies → Company → Contact → Log-interaction, with a breadcrumb trail on Company, Contact, and Log-interaction screens (e.g. Companies / {company name} / {contact name}) for orientation and back-navigation.
- **Home task rows navigate to the task's contact screen** (UX decision; P does not prescribe row navigation, and the contact screen is where the follow-through actions live).

### 1.3 Standard screen states (applies to every authenticated screen)

Every screen distinguishes four mutually exclusive presentations, each visually and semantically distinct (P §1 "Empty state": empty is not a blank screen and not an error):

1. **Loading** — an explicit in-progress indicator (skeleton rows or a labeled spinner) shown while the screen's data request is in flight. Never rendered as an empty list.
2. **Loaded** — the screen content per P §3.
3. **Empty** — P's specified explicit empty-state message plus the specified forward path (per-screen details in §2). Only shown after a successful response containing zero items.
4. **Error** — the request failed. The screen renders the standard error envelope's human-readable content **[Node A seam: error envelope shape]** in an error panel with a **Retry** action that re-issues the read. No partial or stale data is presented as if current.

Two cross-cutting error classes get dedicated full-screen treatments instead of the inline panel:

- **Unauthenticated (P-AUTH-2, P-AUTH-7):** any response in the API's constant 401 class replaces the screen with the **"sign in required"** state — a full-screen message with a single action leading to `/sign-in`. Never partial data. This class covers no/unknown/malformed tokens (P-AUTH-2) **and a token resolving to a deactivated user (P-AUTH-7)**: the server intentionally does not distinguish deactivation from an unknown token (anti-enumeration), so the UI cannot and must not present a distinct "deactivated" state — a deactivated user simply sees "sign in required".
- **Unauthorized (P-AUTH-3b, 4, 6):** any response in the 403 access-denied class — a denial for a revoked/absent membership or a suspended tenant — replaces the screen with a full-screen access-denied state rendering the error envelope's message, with actions to retry and to sign out (present a different token). The UI does not invent sub-categories beyond what the envelope carries **[Node A seam: how the envelope distinguishes unauthenticated vs unauthorized]**; it maps exactly two UI classes (sign-in required vs access denied) onto the envelope's discriminator. Because membership is verified on every request (P-AUTH-3b), this state can appear mid-session on any screen; when it does, previously rendered tenant data is replaced, not left interactive.
- **Not-found:** a record route (`/companies/{id}`, `/contacts/{id}`) whose lookup returns not-found — which, per P §5.4, is deliberately indistinguishable between "does not exist" and "belongs to another tenant" — renders a generic not-found state with a link back to `/companies`. The UI must not speculate about cross-tenant existence; it renders one not-found presentation for both cases by construction.

List growth: Node A's contract paginates the companies, timeline, tasks, and audit lists (limit/offset, default page size 50). Each of these lists therefore carries a **mandatory** explicit "load more" continuation control, shown whenever a further page exists, which appends the next page in place while preserving the server-delivered ordering; the UI never re-sorts client-side. This is how the product's "shows all …" behaviors (P §3.1, §3.2, §3.4, §3.6) are satisfied beyond 50 rows: every row remains reachable through continuation, in P's deterministic order.

### 1.4 Date/time display

All logged date-times, due dates, and audit times are rendered from API-returned values without client-side timezone arithmetic beyond formatting **[Node A seam: date-time representation in responses]**. The one timezone-sensitive input — the next-action date — is governed by §3.3 below.

---

## 2. Screens

### 2.1 Home — open next-action tasks (`/`)

**Loaded state (P §3.1):** a dense table/list of the acting user's **open** next-action tasks in the active tenant. Each row shows exactly:

- the generated task title (verbatim server value; see title table in P §1),
- contact name,
- company name,
- due date,
- the outcome label of the interaction that created it.

**Ordering (rendered exactly as delivered; deterministic per P §3.1):** due date ascending (soonest first) → task creation date-time ascending (older first) → task identifier ascending. The UI performs no client-side re-sorting. Done tasks never appear (server-filtered; the UI adds no status filter control in this slice — tasks are created open and stay open, P §8).

**Empty state:** explicit **"no next actions due"** message and a path (link/button) to the companies screen (`/companies`). Distinct from loading and error per §1.3.

**Loading / error / auth states:** per §1.3.

### 2.2 Companies — list + create (`/companies`)

**Loaded state (P §3.2):** all companies in the active tenant. Each row shows: company name and the count of its contacts. Ordering: company name ascending (case-insensitive), ties by company identifier ascending — rendered as delivered, no client re-sort. Selecting a row navigates to `/companies/{companyId}`.

**Create-company action:** an always-available form region (or disclosure) on this screen with one required field, the company name.

- **Validation error:** a blank or whitespace-only name produces a field-level message on the name field; nothing is created; the entered value is preserved. Validation presentation follows §4 (accessibility).
- **Success:** the new company appears in the list (in its ordered position) and an audit event for the creation is visible on `/audit`. The form clears for the next entry; focus returns to the name field.
- **Submit-in-flight:** the submit control is disabled while the request is in flight to prevent accidental double-create (company creation carries no idempotency key in P; disabling is the UI's only duplicate guard here).

**Empty state:** explicit **"no companies yet"** message with the create-company action prominent.

**Loading / error / auth states:** per §1.3.

### 2.3 Company (`/companies/{companyId}`)

**Loaded state (P §3.3):** the company's name as the page heading, plus the list of its contacts. Each contact row shows: name, email and phone **when present** (absent optional fields are simply not rendered — no placeholder, no error), and last-contacted timestamp or the explicit **"never contacted"** state. Selecting a contact navigates to `/contacts/{contactId}`.

**Create-contact action:** a form on this screen with: required non-empty name, optional email, optional phone.

- **Validation error:** blank name → field-level message on the name field, values preserved, nothing created. Omitting email and phone is valid and produces no error.
- **Success:** the contact appears in the company's contact list showing "never contacted"; an audit event appears on `/audit`.
- **Submit-in-flight:** submit control disabled while in flight (same rationale as §2.2).

**Empty state:** a company with no contacts shows an explicit **"no contacts yet"** message with the create-contact action.

**Not-found:** per §1.3 (covers both nonexistent and cross-tenant IDs identically, P §5.4).

**Loading / error / auth states:** per §1.3.

### 2.4 Contact with timeline (`/contacts/{contactId}`)

**Loaded state (P §3.4):**

- Header block: contact name, owning company (linked to `/companies/{companyId}`), email and phone **when present** (absent optionals not rendered), and last-contacted timestamp or **"never contacted"**.
- Primary action: **log interaction** → `/contacts/{contactId}/log-interaction`.
- **Timeline:** all interactions for this contact, **newest first**, rendered as delivered. Each timeline entry displays: interaction type (call), outcome label (exact label from P §1's outcome table), note (if any; absent note renders nothing), acting user, and logged date-time.
- **Per-entry processing-state affordance:** see §5 (async observability). It is subordinate to the P-defined entry fields and never displays internal fields.

**Post-submit confirmation:** when the user arrives here after a successful log-interaction submission (P §3.5), the screen shows a confirmation indicating the interaction was logged and a next-action task was created, surfacing the created task's generated title (verbatim server value) so the salesperson sees exactly what will appear on Home **[Node A seam: whether the submit response carries the created task's title/record or the UI reads it from the task resource]**. The confirmation is dismissible and announced per §4. The new timeline entry is immediately visible beneath it (P §4 step 5 — synchronous, no background wait).

**Empty state:** a contact with no interactions shows an explicit **"no interactions yet"** message with the log-interaction action, and last-contacted shows **"never contacted"**.

**Not-found / loading / error / auth states:** per §1.3.

### 2.5 Log-interaction form (`/contacts/{contactId}/log-interaction`)

**Context header:** the contact's name and owning company, so the user always knows which relationship they are logging against; breadcrumb back to the contact.

**Fields (P §3.5):**

1. **Interaction type** — fixed to "call" in this slice; displayed as read-only text, not an input (no other types exist, P §8).
2. **Outcome** — required; a selection control (radio group or select — Sprint 0002's choice, but never free text) presenting exactly these five labels, in exactly this order (P §1):
   1. Connected
   2. No answer
   3. Left voicemail
   4. Meeting scheduled
   5. Not interested now
3. **Note** — optional free-text area.
4. **Next-action date** — required date input. Helper text states the rule in tenant terms: the date must be today or later, where "today" is the current date in the tenant's operating timezone (P §1, §5.2). Server validation is authoritative. Client-side pre-validation of "today" is possible only if the tenant's operating timezone (or a server-computed tenant-local today) is available to the client **[Node A seam: whether tenant operating timezone / tenant-local date is exposed]**; absent that, the UI performs no client-side date-floor check and relies on the server's field-level error, because the browser's timezone must never be used as the validation basis.

**Idempotency key lifecycle (P §1, §3.5):** one key is generated when this form instance is opened (route entry / form mount) and reused for every retry of this instance. The key is invisible to the user. Leaving the route discards the instance; returning generates a fresh key (deliberate — the same field values under a new key are a legitimate new interaction, P §5.1 "Contrast").

**Submission states:**

- **In flight:** the submit control is disabled from click until a response arrives (prevents double-click double-submit at the UI layer; the idempotency key makes any race harmless server-side per P §5.1).
- **Success:** navigate to `/contacts/{contactId}` with the confirmation of §2.4. The synchronous results (new timeline entry, updated last-contacted, new Home task with the exact generated title, audit events) are immediately observable per P §4 step 5.
- **Duplicate submission (same key, same payload — e.g. a network timeout followed by the user pressing Try again):** the form offers a **Try again** action on request failure that resubmits the identical payload with the same key. If the first attempt actually succeeded server-side, the retry's response is a success referring to the **same** interaction and task IDs (P §5.1); the UI treats it identically to a first success — same navigation, same confirmation, no "duplicate" messaging. Exactly one timeline entry and one task exist.
- **Request-hash mismatch (same key, different payload):** P §5.1 defines this as a client error with nothing created and originals unchanged. The UI's key lifecycle makes it unreachable through normal use (after success the user leaves the form; the key dies with the instance), but if it occurs (e.g. an unforeseen resubmit path), the UI renders it via the standard error envelope as a form-level error stating the submission conflicts with an earlier one, with the only offered recovery being returning to the contact and opening a fresh form (fresh key). No field values are lost.
- **Validation failure (P §5.2, §5.3):** the user stays on the form; **all entered values are preserved exactly**; a field-level error message names the offending field — the next-action date for a missing/unparseable/past date, the outcome for a missing outcome (hard to trigger via the selection control; the direct-API test is primary per P §5.3). Nothing is created. Error presentation and focus behavior per §4. The same form instance and key remain in use for the corrected resubmit (see Open question 2, §7).
- **Unauthenticated / unauthorized / not-found:** per §1.3; a contact ID that fails the tenant-scoped lookup behaves as not-found (P §5.7).

### 2.6 Audit view (`/audit`)

**Loaded state (P §3.6):** a chronological table, **newest first**, of audit events in the active tenant. Each row displays: **actor, tenant, action, record, time** — where "record" is the affected business record's type and identifier, sufficient for a tester to match it to the record. Rendered as delivered; no client re-sort.

The interaction submission's audit trail must let a tester confirm the interaction and its next-action task resulted from the same submission; the UI therefore renders whatever correlating field(s) the audit rows carry for this purpose without summarizing them away **[Node A seam: the correlating field(s) in audit rows]**.

**Empty state:** explicit **"no audit events"** message.

**Loading / error / auth states:** per §1.3.

---

## 3. Primary workflows (step-by-step)

### 3.1 Sign-in (P §2, journey step 1)

1. User opens any route without a valid token → **"sign in required"** state → `/sign-in`.
2. `/sign-in` presents a dev-token entry (enter/select a seeded token). No token values are ever shown in URLs or logged (P-AUTH-8 hygiene extends to the client: the app never logs token material).
3. On acceptance, the app lands on Home; the header identity block shows the resolved acting user and active tenant (P-AUTH-3). An invalid token re-presents `/sign-in` with the error envelope's message.

### 3.2 The full journey (P §4): company → contact → call → timeline/task/audit

1. **Create company.** Home (likely empty: "no next actions due") → path to Companies → companies empty state ("no companies yet") → create-company form → enter name → submit → company row appears with contact count 0. Detour available: `/audit` shows the creation event (actor = acting user, tenant = active tenant).
2. **Create contact.** Select the company row → Company screen empty state ("no contacts yet") → create-contact form → name (email/phone optional) → submit → contact row appears with "never contacted". `/audit` shows the creation event.
3. **Log the call.** Select the contact → Contact screen empty state ("no interactions yet", "never contacted") → **log interaction** → form opens (new instance, new idempotency key):
   - outcome selector shows the five labels in order — Connected, No answer, Left voicemail, Meeting scheduled, Not interested now;
   - optional note;
   - next-action date with the tenant-timezone "today or later" rule in helper text; an invalid date on submit yields the field-level error naming the next-action date, values preserved (§2.5);
   - submit (control disabled while in flight).
4. **Observe synchronous results (P §4 step 5).** Returned to the contact screen with the confirmation (interaction logged; next-action task created — generated title surfaced): the timeline shows exactly one new entry (chosen outcome label, note, acting user, logged time); last-contacted equals the logged time; Home shows exactly one new open task for this contact with the chosen due date and the exact generated title from P §1's table (e.g. outcome Connected → "Continue the conversation with {contact name}."; Not interested now → "Review disposition: close out or set a re-engagement date."); `/audit` shows the submission's audit event(s) with actor, tenant, action, record, time.
5. **Observe asynchronous results (P §4 step 6).** On the new timeline entry, the processing-state affordance (§5) progresses to **processed** within the 30-second local bound — typically via published, though polling may not observe every intermediate state. No additional task, timeline entry, or contact change appears from background processing (P §6.5).

### 3.3 Retry and duplicate flows

- **Network failure on submit:** form-level error (envelope message) + **Try again** → same key, same payload → outcome per §2.5 duplicate handling (single creation guaranteed; success references the same IDs).
- **Validation failure:** field-level error, preserved values, correct and resubmit (same instance/key).
- **Mid-session denial:** any step's request may return unauthorized (revocation or suspension — P-AUTH-3b/4/6), replacing the current screen with the access-denied state (§1.3); a mid-session deactivation (P-AUTH-7) instead surfaces as the constant 401 and lands on the "sign in required" state, indistinguishable from an unknown token per §1.3. No write survives a prior-committed revocation (server-guaranteed; the UI simply renders the denial and never retries writes automatically).

---

## 4. Accessibility baselines (pragmatic)

- **Form labeling:** every input has a programmatically associated visible label; the outcome selection control is a labeled group; helper text (e.g. the next-action-date rule) is programmatically associated with its input.
- **Error announcement:** field-level validation messages are programmatically associated with their field and announced via an assertive live region on submission failure; form-level and screen-level errors use an alert role. Success confirmations (§2.4) use a polite live region.
- **Focus handling on validation failure:** focus moves to the first invalid field; its associated error message names the field and the problem. On screen-level error states, focus moves to the error panel's heading; the Retry control is keyboard-reachable.
- **Semantics:** task, company, contact, and audit lists use table or list semantics with header cells / labeled fields so row structure (e.g. actor/tenant/action/record/time) is navigable by assistive technology. Loading states are announced (busy semantics), and empty states are real text content, not styling artifacts.
- **Navigation:** the identity block and global nav are landmarks; breadcrumbs are a labeled navigation region; every interactive element is keyboard-operable.

---

## 5. Async-path observability in the UI

**Purpose:** make P §4 step 6 observable in the browser — the journey's outbox event reaching **processed** — closing the deferred browser-only portion of AC-1 (WAVE1_FREEZE Obligation 3).

**Data source:** Node A's authenticated, tenant-scoped event-processing inspection endpoint **[Node A seam — endpoint shape, joinability field, and polling semantics are owned by Node A; this section designs placement only]**. The surface obeys the same auth/tenant/not-found rules as everything else (P §6.4), so its UI states inherit §1.3 unchanged.

**Placement and affordance:**

- Each **timeline entry** on the contact screen carries a compact **processing-state indicator** showing exactly one of the four operator-facing states, labeled with P §6.4's state names: **processed**, **failed**, **published**, **pending** (precedence is server-decided; the UI renders the single state the endpoint reports and never re-derives precedence client-side).
- While a just-submitted interaction is not yet **processed**, the UI polls the inspection endpoint at a modest interval (implementation detail for Sprint 0002; the local acceptance bound is 30 seconds) and updates the indicator until it reaches **processed** — typically via **published**, though intermediate states may not be observed by polling (a fast pipeline can move pending → processed between polls; the UI renders whatever state each poll reports and never fabricates missed intermediates). Polling stops at processed.
- **Transient failed states are not treated as terminal.** Below the retry ceiling, automatic retries continue server-side and the derived state may later leave `failed` (e.g. return to published and reach processed). The indicator therefore renders `failed` as the *current* state, not a frozen endpoint: the UI resumes/refreshes the state on re-poll or page reload rather than latching a stale terminal-looking `failed`. Automated UI tests must likewise not treat a single `failed` reading below the ceiling as terminal.
- **Failed state detail:** activating a failed indicator opens a detail disclosure showing `failure_stage` (**publication** or **consumer**) and the last error's operator-facing summary (sanitized upstream per WAVE1_FREEZE Obligation 2; the UI renders it as opaque text and never parses it). Secondary consumer-failure diagnostic detail, when present, is shown beneath the primary stage. No retry/replay controls exist in this UI in this slice (recovery is an operator action outside the web app).
- **Confidentiality rule (restated):** the indicator and detail views render only: state name, `failure_stage`, and the sanitized last-error summary, plus whatever join identifier ties it to the interaction. **`seq`, `claim_id`, lease details, topic/partition/offset, or any other internal field are never rendered**, even if the endpoint were to return them.
- **Degradation:** until the Node A endpoint exists, the indicator region is simply absent (not a broken placeholder); this document reserves its placement so adding it is additive. An inspection-endpoint error shows a minimal inline "state unavailable" note with retry — it never blocks or degrades the P-defined timeline content around it.

---

## 6. Responsive behavior

**Posture: desktop-first.** This is a CRM operated by a salesperson at a desk (charter first user: the founder); the dense multi-column task/company/audit tables and the side-by-side form-plus-list layouts are optimized for ≥1280px-wide viewports. Narrow-viewport support is a readability fallback, not a mobile product (P §8: no mobile-native app).

Per-screen narrow-viewport (<~768px) behavior:

- **Global header:** identity block (user + tenant) remains always visible, abbreviated to fit on one line if needed but never removed; global nav collapses into a disclosure menu.
- **Home:** the task table collapses to stacked cards, each card preserving all five P-required fields (generated title, contact, company, due date, outcome label) and the delivered order.
- **Companies:** two-column row (name, contact count) remains a single-line row; the create form stacks above the list.
- **Company:** contact rows collapse to stacked cards (name; email/phone when present; last-contacted or "never contacted"); the create-contact form stacks.
- **Contact:** header block stacks; timeline entries are already card-like and reflow naturally; the processing-state indicator stays attached to its entry.
- **Log-interaction form:** single-column at all widths (forms gain nothing from columns); the outcome selection control stacks vertically preserving the five-label order.
- **Audit:** the five-field rows collapse to stacked cards labeling each field (actor, tenant, action, record, time) so no field is dropped at any width.

Invariant at every width: no P-required field is elided, orderings are unchanged, and empty/loading/error states remain distinct.

---

## 7. Open questions for the lead / Node A (none block Wave-2 authoring)

1. **Tenant timezone exposure (§2.5):** does the API expose the tenant's operating timezone (or a tenant-local "today") so the date input can pre-validate client-side? If not, the form relies solely on server-side field-level errors — acceptable, but a worse first-attempt experience. [Node A]
2. **Idempotency key after a validation failure (§2.5):** P §5.2 says a validation failure creates nothing, and P §1 says the form instance reuses its key for retries; this document therefore reuses the key on corrected resubmits. If Node A's idempotency contract binds a key's payload hash on *rejected* attempts, the form must instead regenerate the key after a validation failure — please confirm which. [Node A]
3. **Generated-title surfacing on the confirmation (§2.4):** confirm whether the submit response (or an immediate subsequent fetch of the task resource) provides the created task's title/record so the confirmation shows server truth rather than a client-recomputed string. [Node A]
4. **Audit correlation field (§2.6):** confirm what audit rows carry that lets a tester link the interaction and its task to one submission, so the audit UI renders it. [Node A]

---

## 8. Self-verification against the acceptance checklist

- Every P screen has routes, contents, and all four states (§2.1–2.6), plus the sign-in gate for P §2: yes.
- Every P §5 edge case is represented as user-visible flow/state: 5.1 duplicate + request-hash mismatch + in-flight disabling (§2.5, §3.3); 5.2 date validation with preserved values and tenant-timezone rule (§2.5, §3.2); 5.3 outcome validation (§2.5); 5.4 cross-tenant = not-found presentation (§1.3, §2.3, §2.4); 5.5 all five empty states with P's exact messages (§2); 5.6 unauthenticated/unauthorized full-screen states (§1.3, §3.3); 5.7 referential not-found (§2.5).
- P-AUTH-2..7 appear as user-visible behavior (§1.3, §3.1, §3.3), classified consistently with the API's response classes: P-AUTH-2 and P-AUTH-7 in the constant-401 sign-in-required class (deactivation deliberately indistinguishable from an unknown token, anti-enumeration), P-AUTH-3b/4/6 in the 403 access-denied class; identity block always visible (§1.2, §6).
- Pagination is affirmative, not conditional: companies, timeline, tasks, and audit paginate (limit/offset, default 50) per Node A's contract, with a mandatory "load more" continuation, no client re-sort, and P's "shows all" behaviors satisfied beyond 50 rows through continuation (§1.3).
- Exact P copy used verbatim: five outcome labels in order incl. "Not interested now"; generated-title examples quoted from P's table; empty-state messages "no next actions due", "no companies yet", "no contacts yet", "no interactions yet", "no audit events", "never contacted"; "sign in required"; orderings restated exactly (tasks: due date asc → creation asc → id asc; companies: name asc case-insensitive → id asc; timeline newest-first with type/outcome label/note/actor/logged date-time; audit newest-first with actor/tenant/action/record/time).
- Async observability designed as placement + affordance only; four states and failure_stage per P §6.4; progression stated as "reaches processed — typically via published; intermediate states may not be observed by polling"; transient `failed` below the retry ceiling is rendered as current-not-terminal, with state resumed on re-poll/reload and a matching constraint on automated tests; endpoint marked as Node A seam; `seq`/`claim_id`/internal fields banned from the UI (§5, preamble).
- No API shapes invented: every data/error dependency is a marked [Node A seam]; unresolved contract questions are listed in §7 instead of being answered here.
- No Wave-1 contradiction found; no Wave-1 file modified.
