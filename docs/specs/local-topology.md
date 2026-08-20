# Local Development Topology Contract (Sprint 0001, Node I)

Status: **Documentation only.** This file is the contract for the Docker Compose
topology that Sprint 0002 will implement. **No compose file, container, image,
volume, or network is created by Sprint 0001.** All commands in section 8 are
*documented for Sprint 0002* and were **not executed** while authoring this
contract, except the read-only diagnostics recorded in section 3.

Cost floor: **$0. Everything runs locally.** No cloud resources, no paid
services, no always-on remote infrastructure. Idle cost is zero when the
Compose project is down.

---

## 1. Scope and constraints

- First vertical slice only (see `docs/FIRST_VERTICAL_SLICE.md`): web UI,
  TypeScript API, one background worker, PostgreSQL (authoritative), ordinary
  Apache Kafka.
- No schema registry container. Events are JSON validated against JSON Schema
  files in the monorepo (`packages/*`).
- Explicitly excluded (per CLAUDE.md / charter): Kubernetes, Spark, OpenSearch,
  Temporal, Flink, ClickHouse, MongoDB, DynamoDB, cloud infrastructure.
- This machine runs unrelated containers. Isolation comes from **Compose
  project scoping**: the compose file sets `name: crmlab`, and every physical
  resource name (containers, volumes, networks) is *derived* by Compose from
  that project name. Nothing is daemon-globally pinned, and all lifecycle
  commands are project-scoped, so nothing outside this project is ever touched.
- **Trust boundary.** The local trust boundary is the developer machine
  itself: the published `crmlab`/`crmlab` PostgreSQL credentials and the
  PLAINTEXT Kafka listener are non-secret by construction because every socket
  is loopback-only. This assumption must be deliberately invalidated — real
  credentials, TLS, SASL/SCRAM — before any non-loopback deployment.

## 2. Topology overview

Two containers in Docker Compose; three Node processes on the host.

Naming contract: commands address stable Compose **service** keys (`postgres`,
`kafka`). Compose derives physical names from the project name — e.g.
container `crmlab-postgres-1`, volume `crmlab_postgres-data`, network
`crmlab_default`. `container_name` is deliberately **absent** from the compose
file because pinned container names are daemon-global and collide the moment a
second project instance (test run, second worktree) starts. The same applies
to volumes and networks: no daemon-global `name:` pinning anywhere.

| Component        | Runs where     | Compose service key | Derived resources (project `crmlab`) |
|------------------|----------------|---------------------|--------------------------------------|
| PostgreSQL 16    | Docker Compose | `postgres`          | container `crmlab-postgres-1`, volume `crmlab_postgres-data` |
| Apache Kafka     | Docker Compose | `kafka` (KRaft, 1 node) | container `crmlab-kafka-1`, volume `crmlab_kafka-data` |
| API (TypeScript modular monolith) | Host, `npm` | n/a  | n/a |
| Web (Next.js)    | Host, `npm`    | n/a                 | n/a |
| Worker           | Host, `npm`    | n/a                 | n/a |
| Network          | Docker Compose | default network     | `crmlab_default` (bridge) |

### Parallel instances (supported isolation mechanism)

Because nothing is daemon-globally pinned, running additional isolated
instances is explicitly **permitted and supported** by choosing a unique
project name per test run or worktree, e.g.:

```
docker compose -p crmlab-test up -d
docker compose -p crmlab-wt2 up -d
```

Each project gets its own containers, volumes, and network with no collisions.
(Host ports still collide; parallel instances must override the port variables
in section 9 — e.g. ephemeral ports for integration tests.)

### Why app processes run on the host (recommendation)

`apps/web`, `apps/api`, and `apps/worker` run on the host with npm workspaces,
not inside Compose, for the first slice:

1. **Dev loop speed.** Hot reload / TS incremental compile in milliseconds; no
   image rebuild, no bind-mount + file-watcher flakiness on Windows (Compose
   bind mounts across the Windows/WSL2 boundary make Next.js and tsx watchers
   slow or blind to changes).
2. **Debugging.** Native Node debugger / IDE attach with zero port-forward
   ceremony.
3. **Worker restart tests.** The vertical slice requires killing and restarting
   the worker; a host process is trivially killable from the test harness.
4. **Nothing is lost.** The app processes are stateless; only stateful infra
   (Postgres, Kafka) benefits from containerization. Containerizing the apps is
   deferred until a deployment-shaped milestone needs it.

### Why Kafka in KRaft single-node mode (recommendation)

- KRaft eliminates the ZooKeeper container entirely: one fewer container, one
  fewer image, fewer ports, faster startup, lower idle RAM — consistent with
  "world-class seams, tiny fleet."
- KRaft is the only supported metadata mode in Kafka 4.x; ZooKeeper mode is
  removed upstream, so a KRaft dev topology matches any future production.
- A single combined broker+controller node with replication factor 1 is
  sufficient for local development. PostgreSQL is authoritative, and lost
  Kafka data is recoverable via the outbox replay procedure in section 6 —
  **provided PostgreSQL and its outbox table survive** (section 6
  precondition).

### Proposed image pins (verified/refreshed by Sprint 0002 at implementation)

| Service    | Proposed pin           | Notes                                  |
|------------|------------------------|----------------------------------------|
| `postgres` | `postgres:16.6`        | PostgreSQL major version 16 is frozen for the slice. |
| `kafka`    | `apache/kafka:3.9.1`   | Official Apache image, KRaft-native.   |

These are **implementation-time pins, not final**: Sprint 0002 verifies each
tag exists, refreshes to the current patch release of the same major/minor
line if one has shipped, and records the exact digest-pinned versions in the
compose file. `latest` is never used.

## 3. Recorded diagnostics (read-only, 2026-08-19)

Commands run while authoring this contract: `docker ps`, `docker ps -a`,
`docker version`, `netstat -ano -p TCP`. No state-mutating docker command was
run. What these checks established, and nothing beyond it:

- Zero containers were running at check time.
- Three stopped containers existed, all unrelated to this project
  (`docker/welcome-to-docker` images), with no published port bindings.
- The complete set of listening TCP ports at check time was:
  `135, 139, 445, 664, 2179, 5040, 16993, 49664, 49665, 49666, 49667, 49668, 49673`.
- Docker Engine server version reported: 29.7.2.

These are point-in-time measurements on this one machine; they do not describe
other developer machines or future states.

## 4. Host ports

All published ports bind to loopback only — the compose mapping form is
`"127.0.0.1:<host-port>:<container-port>"` — and the host-run web/API dev
servers likewise bind `127.0.0.1`, never `0.0.0.0`. Nothing in this topology
is reachable from the LAN.

Port status below is derived from the section 3 listening-port measurement: a
port is marked FREE if it did not appear in that set at check time.

| Host port | Assigned to | Compose mapping | Check result |
|-----------|-------------|-----------------|--------------|
| 5432 (`POSTGRES_PORT`) | service `postgres` | `"127.0.0.1:${POSTGRES_PORT}:5432"` | FREE |
| 9092 (`KAFKA_PORT`)    | service `kafka`, EXTERNAL listener | `"127.0.0.1:${KAFKA_PORT}:9092"` | FREE |
| 9093 | `kafka` KRaft controller listener | not published (internal to the project network) | FREE (not published anyway) |
| 9094 | `kafka` INTERNAL broker listener (future in-compose clients) | not published | FREE (not published anyway) |
| 3000 (`WEB_PORT`) | `apps/web` dev server, host process on 127.0.0.1 | n/a | FREE |
| 3001 (`API_PORT`) | `apps/api` dev server, host process on 127.0.0.1 | n/a | FREE |
| —    | `apps/worker` | no listening port | n/a |

No conflicts found on this machine; no alternates needed here. If a conflict
appears on another developer machine, the fallbacks are: Postgres → 5433,
Kafka → 9095, web → 3100, api → 3101 — changed **only** by editing
`POSTGRES_PORT` / `KAFKA_PORT` / `WEB_PORT` / `API_PORT` in the local `.env`
(section 9), never by editing the compose file ad hoc.

Kafka listener contract (for Sprint 0002):

- `EXTERNAL` listener advertised as `localhost:${KAFKA_PORT}` — used by
  host-run api, worker, and tests.
- `INTERNAL` listener advertised as `kafka:9094` on the project network —
  reserved for any future in-compose client; nothing uses it in the first
  slice.
- `CONTROLLER` on 9093 — never published to the host.

## 5. Volumes and persistence

Volumes are declared in the compose file with project-relative keys and get
project-derived physical names (for project `crmlab`):

- `postgres-data` → `crmlab_postgres-data` (service `postgres`): all
  authoritative CRM data — business records, audit log, outbox, migration
  state.
- `kafka-data` → `crmlab_kafka-data` (service `kafka`): topic logs and KRaft
  metadata. Persisting this across restarts is required for the "worker
  restart loses nothing" acceptance test.

Data survives `docker compose -p crmlab down` and machine reboots.

### Teardown vs. full reset

Non-destructive teardown (normal daily use — data is kept):

```
docker compose -p crmlab down
```

Destructive full reset:

```
docker compose -p crmlab down -v
```

> **WARNING — DESTRUCTIVE.** `down -v` destroys **both** the authoritative
> PostgreSQL data (`crmlab_postgres-data` — every company, contact,
> interaction, task, audit record, and outbox row; PostgreSQL is the system of
> record) **and** all Kafka topic data (`crmlab_kafka-data`). There is no
> undo. With no backup, what you get afterwards is a **fresh migrated/seeded
> environment, not a restoration of the previous one** — re-run migrations,
> seeds, and topic initialization from scratch. No automated backup mechanism
> is part of Sprint 0001; if your local history matters, take a manual
> `pg_dump` first, e.g.
> `docker compose -p crmlab exec postgres pg_dump -U crmlab crmlab > backup.sql`.

Scoping guarantee: because all volume names are project-derived (nothing
daemon-globally pinned), `down -v` with `-p crmlab` removes only the volumes
belonging to the `crmlab` project. That guarantee is exactly why pinned
`name:` declarations are banned — with them, `-v` could delete a volume shared
by name with another project instance. Unrelated containers, images, networks,
and volumes on the machine are untouched. **Never** use
`docker system prune`, `docker volume prune`, or unscoped
`docker rm`/`docker volume rm` for resetting this project.

## 6. Derived-data recovery: outbox replay (Sprint 0002 deliverable)

> **Precondition: replay can reconstruct Kafka ONLY when PostgreSQL and its
> outbox table survive.** If the PostgreSQL volume is destroyed (e.g. by
> `down -v`), there is nothing to replay from and Kafka history is
> unrecoverable; you are starting a fresh environment (section 5).

Given that precondition, Sprint 0002 must ship an explicit replay procedure:

1. `npm run outbox:replay --workspace apps/worker` (name illustrative)
   re-publishes outbox rows from PostgreSQL to Kafka, in outbox insertion
   order, optionally filtered by tenant and/or time range. Each re-published
   message carries the **original** event ID and tenant ID.
2. Consumers keep an idempotency receipt table in PostgreSQL (processed event
   ID per consumer, tenant-scoped). During replay, already-processed events
   are acknowledged without re-executing side effects, so replay is safe to
   run repeatedly and after partial failures.
3. Replay performs no external side effects itself; it only writes to Kafka.
   Side-effect protection lives entirely in the consumers' receipts.

## 7. Health checks, startup ordering, and process guards

### Compose health checks

- Service `postgres`: `pg_isready -U crmlab -d crmlab`; interval 5s, timeout
  3s, retries 10.
- Service `kafka`:
  `/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092`;
  interval 10s, timeout 10s, retries 12, start_period 20s.

### Host process health endpoints

- `apps/api` exposes two distinct endpoints:
  - `GET /livez` — liveness: returns 200 whenever the process is up and
    serving HTTP. No dependency checks.
  - `GET /readyz` — readiness: returns 200 only when PostgreSQL is reachable
    and migrations are applied. **Kafka availability must NOT gate `/readyz`.**
    The synchronous CRM write path (interaction + task + audit + outbox in one
    PostgreSQL transaction) requires only PostgreSQL; if Kafka is down, the
    API stays ready, outbox rows accumulate, and the publisher catches up when
    Kafka returns. `/readyz` may *report* Kafka status informationally in its
    body, but never fail because of it.
- `apps/worker`: logs a ready line after joining its Kafka consumer group; no
  listening port.
- Authn/authz **denial logs** are written to the API process stdout/log stream
  as structured events carrying the exact canonical denial-event fields
  defined by **P-AUTH-8** in the product behavior contract, including route.
  P-AUTH-8 is the sole source of truth for that field list; this document
  deliberately does not define a second list that could drift. This is where
  Node P's denial-logging requirement is satisfied locally.

### Loopback enforcement (startup assertion)

Node and Next.js default to listening on all interfaces, so loopback-only is
enforced in code, not by convention: the shared config module **fails fast at
startup if the resolved listen host is anything other than `127.0.0.1` while
dev-token mode is active**, and an automated test asserts that every listening
socket opened by api/web is loopback-bound.

### Startup ordering

1. Services `postgres` and `kafka` start in parallel; each has its own health
   check and neither depends on the other.
2. Anything later added *inside* Compose must use
   `depends_on: { postgres: { condition: service_healthy } }` (and likewise
   for `kafka`) — never bare `depends_on`.
3. **Topic initialization (Sprint 0002 requirement).** Kafka topics are
   created by a deterministic, idempotent init step — either a repo script
   (e.g. `npm run kafka:init-topics`) or a short-lived compose init service —
   that runs `kafka-topics.sh --create --if-not-exists` for every topic the
   slice needs, with explicit partition and retention settings. It must be
   safe to run repeatedly. Broker auto-creation
   (`auto.create.topics.enable`) is disabled; the topology never relies on
   auto-create. Topic names in this document (e.g. `crm.events.v1`) are
   **illustrative only**; the real names are owned by Node E's event contract.
   The illustration is deliberately domain-oriented (`crm.events.v1`, not
   `crm.outbox.v1`) so the wire contract does not encode the outbox mechanism.
4. Host processes start after infra is healthy. Sprint 0002 adds an npm script
   (e.g. `npm run dev:wait-infra`) that polls TCP connect on
   `127.0.0.1:${POSTGRES_PORT}` and `127.0.0.1:${KAFKA_PORT}` with a bounded
   timeout; then the developer runs migrations (`npm run db:migrate` or via
   api startup), then api → worker → web.
5. The worker tolerates Kafka being briefly unavailable (bounded retry with
   backoff); at-least-once delivery plus idempotency receipts make late joins
   and reconnects safe.

## 8. Developer commands (Sprint 0002 — documented, not executed in Sprint 0001)

All lifecycle commands are project-scoped with `-p crmlab` (or a per-instance
project name, section 2) and address Compose **service** keys (`postgres`,
`kafka`), never physical container names.

| Action | Command |
|--------|---------|
| Bring up infra | `docker compose -p crmlab up -d` |
| Tear down, keep data | `docker compose -p crmlab down` |
| Full reset — DESTRUCTIVE, erases authoritative local data (see section 5 warning) | `docker compose -p crmlab down -v` |
| Tail all infra logs | `docker compose -p crmlab logs -f` |
| Tail one service | `docker compose -p crmlab logs -f postgres` |
| psql shell | `docker compose -p crmlab exec postgres psql -U crmlab -d crmlab` |
| Manual backup before a reset | `docker compose -p crmlab exec postgres pg_dump -U crmlab crmlab > backup.sql` |
| Kafka console consumer | `docker compose -p crmlab exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic crm.events.v1 --from-beginning` |
| List Kafka topics | `docker compose -p crmlab exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list` |
| Force redelivery (canonical for duplicate-event test) | `docker compose -p crmlab exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --group crm-worker --topic crm.events.v1 --reset-offsets --to-earliest --execute` (consumer group must be stopped) |
| Initialize topics (idempotent) | `npm run kafka:init-topics` |
| Start api (host) | `npm run dev --workspace apps/api` |
| Start web (host) | `npm run dev --workspace apps/web` |
| Start worker (host) | `npm run dev --workspace apps/worker` |

Redelivery mechanism for the duplicate-event acceptance test: the
**`kafka-consumer-groups.sh` offset reset is canonical** because it forces the
broker to redeliver the *identical, already-published* messages through the
real consumer path with zero bespoke code, which is exactly the at-least-once
condition the test must prove. The Sprint 0002 outbox replay script
(section 6) is the documented alternative when a targeted or filtered
re-publish is needed.

The compose file itself (authored in Sprint 0002) must set `name: crmlab` so
the project scope holds even if a developer forgets `-p`. Topic and group
names above are illustrative pending Node E's event contract.

## 9. Environment variable conventions

- The repo commits **`.env.example` only**, with every required variable and a
  safe local default or placeholder. Real `.env` files are gitignored and
  **never committed** (per CLAUDE.md safety rules).
- Each app workspace reads the root `.env`; variables are validated at process
  start via a shared config module in `packages/` (fail fast on
  missing/invalid).

### Single source of truth for ports and connection strings

To prevent drift between compose port mappings and application connection
strings, ports are defined **once** and everything derives from them:

- `POSTGRES_PORT` is consumed by the compose mapping
  (`"127.0.0.1:${POSTGRES_PORT}:5432"`) **and** by the shared config module,
  which constructs the database URL as
  `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB}`.
- `KAFKA_PORT` is consumed by the compose mapping
  (`"127.0.0.1:${KAFKA_PORT}:9092"`) and the advertised EXTERNAL listener,
  **and** the config module constructs `KAFKA_BROKERS` as
  `127.0.0.1:${KAFKA_PORT}`.
- `.env.example` contains **no** independently hand-written `DATABASE_URL` or
  `KAFKA_BROKERS`; those values exist only as derived outputs of the config
  module. Changing a port in one place cannot desynchronize the other.

### Variables in `.env.example`

| Variable | Local default | Notes |
|----------|---------------|-------|
| `APP_ENV` | `local` | Environment discriminator: `local` \| `test` \| future values. |
| `AUTH_MODE` | `dev-token` | Auth mode selector; unset or unknown values fail startup (section below). |
| `POSTGRES_USER` | `crmlab` | Dev-only, loopback-only credentials; non-secret by construction within the section 1 trust boundary. |
| `POSTGRES_PASSWORD` | `crmlab` | Same as above. |
| `POSTGRES_DB` | `crmlab` | |
| `POSTGRES_PORT` | `5432` | Single source of truth (fallback 5433). |
| `KAFKA_PORT` | `9092` | Single source of truth (fallback 9095). |
| `API_PORT` | `3001` | API binds `127.0.0.1` (fallback 3101). |
| `WEB_PORT` | `3000` | Web binds `127.0.0.1` (fallback 3100). |

### Dev-token auth stub guard (frozen decision, hardened convention)

The guard is **multi-factor** — `APP_ENV` alone is not trusted. At boot, the
api process exits non-zero with an explicit error, before binding its port,
if **any** of the following holds:

1. `AUTH_MODE` is unset or has an unknown value (fail closed; no default).
2. `AUTH_MODE=dev-token` and `APP_ENV` is not `local` or `test`.
3. `AUTH_MODE=dev-token` and `NODE_ENV=production`.
4. `AUTH_MODE=dev-token` and the resolved bind address is not `127.0.0.1`
   (ties into the section 7 loopback assertion).

There is no override flag. Dev tokens themselves are **seeded random values
of at least 128 bits of entropy, generated at seed time and stored only in
the local database — never committed to the repository** (not in
`.env.example`, fixtures, or docs). This makes it impossible to ship the stub
— or a well-known token — to any non-local environment by configuration drift.

## 10. Acceptance self-check (Sprint 0001)

- No state-mutating docker command is part of any Sprint 0001 setup path; all
  lifecycle commands above are labeled Sprint 0002 documentation, and the
  section 3 diagnostics were read-only.
- Every proposed host port has a recorded FREE/CONFLICTED result (sections
  3–4) and binds to 127.0.0.1 only, with loopback enforced by a startup
  assertion and an automated socket check (section 7).
- No daemon-globally pinned resource names: no `container_name`, no volume or
  network `name:` pinning. All physical names are Compose-derived from the
  project name (`crmlab-postgres-1`, `crmlab_postgres-data`,
  `crmlab_kafka-data`, `crmlab_default`), commands address service keys, and
  unique project names per test run/worktree are the supported isolation
  mechanism.
- `down -v` is documented as destructive to both authoritative and derived
  data, with a manual `pg_dump` escape hatch; outbox replay is documented with
  its PostgreSQL-survival precondition.
- Services are limited to the approved list: PostgreSQL, Apache Kafka, and the
  three host-run TypeScript processes. No Kubernetes, Spark, OpenSearch,
  Temporal, Flink, ClickHouse, MongoDB, DynamoDB, schema registry, or cloud.
- Topic and consumer-group names are marked illustrative and deferred to
  Node E's event contract.
- Cost floor: $0, local only.
