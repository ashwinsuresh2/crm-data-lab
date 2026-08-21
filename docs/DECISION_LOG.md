# Decision Log

Use one entry per meaningful architectural or product decision.

## Template

### ADR-XXXX: Decision title

- **Status:** proposed | accepted | superseded
- **Date:** YYYY-MM-DD
- **Decision owner:**
- **Problem:**
- **Options considered:**
- **Decision:**
- **Why:**
- **Consequences:**
- **Monthly fixed-cost impact:**
- **Replacement boundary:**
- **Rollback path:**
- **Evidence required to revisit:**

---

### ADR-0001: Dev-token authentication seam for the first vertical slice

- **Status:** accepted
- **Date:** 2026-08-20
- **Decision owner:** Founder (ruled at the Sprint-0001 barrier gate; ratified at the contract freeze)
- **Problem:** The vertical slice requires authentication, tenant-membership resolution, and authorization, but building a full credential system now would delay the slice without exercising the correctness properties the slice exists to prove.
- **Options considered:** (1) seeded users with email/password sessions; (2) full self-serve signup; (3) dev-token stub.
- **Decision:** Dev-token stub: a dedicated `X-Dev-Token` header resolves to a seeded user bound to one active tenant. The full authenticate → resolve-membership → authorize pipeline is real and fully tested; only credential verification is stubbed, behind a removable auth-middleware seam. Tokens are seeded random values (≥128-bit), stored only in the local database, never committed. The stub is multi-factor fail-closed: unknown `AUTH_MODE` fails startup; dev-token mode refuses to start unless `APP_ENV` is local/test, `NODE_ENV` is not production, and the resolved bind address is loopback.
- **Why:** Preserves every security-relevant behavior the acceptance criteria test (tenant isolation, membership revocation incl. the in-transaction `FOR SHARE` recheck, cross-tenant not-found indistinguishability, denial logging) while deferring only the credential-entry surface.
- **Consequences:** Sprint 0002 implements the pipeline exactly as contracted; replacing the stub with real credentials later touches only the credential-verification step (documented seam: future `user_credential` table). Deactivated users receive the same constant 401 as unknown tokens (anti-enumeration).
- **Monthly fixed-cost impact:** $0 (local only).
- **Replacement boundary:** the auth middleware seam; `X-Dev-Token` is removable without touching authorization or tenant scoping.
- **Rollback path:** none needed pre-exposure; the guard prevents the stub from ever starting outside local/test.
- **Evidence required to revisit:** first external tenant or any non-loopback deployment (both contractually require replacing the stub first).

### ADR-0002: JSON + JSON Schema event serialization

- **Status:** accepted
- **Date:** 2026-08-20
- **Decision owner:** Founder (ruled at Sprint-0001 planning; ratified at the contract freeze)
- **Problem:** Outbox/Kafka events need a serialization format and evolution discipline; CLAUDE.md left JSON Schema/Avro/Protobuf open.
- **Options considered:** (1) JSON + JSON Schema; (2) Avro + schema registry; (3) Protobuf.
- **Decision:** JSON envelopes validated by JSON Schema draft 2020-12 in strict mode with format assertion enabled (annotation-only format validation contractually insufficient). Versioned twelve-field envelope (`event-envelope.v1.schema.json`); per-event-type payload schemas (`interaction-logged.v1.schema.json`); envelope `event_id` MUST equal `outbox_event.id`; no schema registry container.
- **Why:** Human-readable replay/debugging, zero additional fleet (no registry), open format, and strict-mode validation gives loud failure on drift. The payload schema deliberately pins the product-owned outcome vocabulary (closed enum) — a vocabulary change is a payload-schema major bump, deploy-consumers-first — the right discipline while producer and consumer co-deploy from one repo.
- **Consequences:** Migration to Avro/Protobuf later happens behind Node E's client boundary with an ADR. Replay promises logical-value identity, not byte identity (`jsonb` storage does not preserve bytes). Payload excludes free-text notes (data minimization).
- **Monthly fixed-cost impact:** $0 (no registry).
- **Replacement boundary:** Node E's event contract + schemas; the wire format is engine-neutral (works unchanged on Kafka-compatible engines).
- **Rollback path:** schemas are versioned files; a bad schema version is rolled back by republishing under the prior version from the outbox.
- **Evidence required to revisit:** a consumer deploying independently of the API (enum pinning), or cross-language consumers needing binary compactness (format).

### ADR-0003: npm workspaces monorepo

- **Status:** accepted
- **Date:** 2026-08-20
- **Decision owner:** Founder (ruled at Sprint-0001 planning; ratified at the contract freeze)
- **Problem:** The TypeScript modular monolith needs a repository layout and package manager before implementation.
- **Options considered:** (1) npm workspaces monorepo; (2) pnpm workspaces; (3) single package without workspaces.
- **Decision:** npm workspaces monorepo: `apps/web`, `apps/api`, `apps/worker`, `packages/*`, using npm (v11 already installed; `scripts/verify.ps1` already supports it).
- **Why:** Zero new tooling; workspace boundaries express the modular-monolith seams (web/api/worker as separate processes, shared packages for contracts/config) without a service split; pnpm adds a setup step for no slice-level benefit.
- **Consequences:** Sprint 0002 scaffolds this layout; the shared config package is the single source of truth for ports/URLs (I §7 anti-drift rule); the worker stays an easily killable host process (required by the restart acceptance test).
- **Monthly fixed-cost impact:** $0.
- **Replacement boundary:** package-manager choice is invisible to all contracts; switching to pnpm later is a tooling-only change.
- **Rollback path:** collapse to a single package is mechanical if workspaces prove heavy (not expected).
- **Evidence required to revisit:** install-time pain or hoisting bugs materially slowing the dev loop.
