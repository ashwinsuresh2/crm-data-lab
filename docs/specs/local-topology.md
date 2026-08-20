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
- This machine runs unrelated containers. Every project-created Docker
  resource (container, volume, network) carries the `crmlab-` prefix, and all
  lifecycle commands are scoped with the Compose project name `crmlab` so that
  nothing outside this project is ever touched.

## 2. Topology overview

Two containers in Docker Compose; three Node processes on the host.

Naming contract: Compose **service** names are stable, unprefixed identifiers
(`postgres`, `kafka`) — these are what every `docker compose` command
addresses. The compose file additionally pins `container_name` to the
`crmlab-` prefixed values below so that `docker ps` output is unambiguous next
to unrelated containers. Commands never address container names.

| Component        | Runs where     | Compose service | Pinned container_name | Volume |
|------------------|----------------|-----------------|-----------------------|--------|
| PostgreSQL 16    | Docker Compose | `postgres`      | `crmlab-postgres`     | `crmlab-postgres-data` |
| Apache Kafka     | Docker Compose | `kafka` (KRaft, 1 node) | `crmlab-kafka` | `crmlab-kafka-data` |
| API (TypeScript modular monolith) | Host, `npm` | n/a | n/a | n/a |
| Web (Next.js)    | Host, `npm`    | n/a             | n/a                   | n/a |
| Worker           | Host, `npm`    | n/a             | n/a                   | n/a |
| Network          | Docker Compose | —               | `crmlab-net` (bridge) | — |

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
  sufficient for local development. Durability of business truth does not
  depend on Kafka: PostgreSQL is authoritative, and lost Kafka data is
  recoverable via the outbox replay procedure in section 6.

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
| 9093 | `kafka` KRaft controller listener | not published (internal to `crmlab-net`) | FREE (not published anyway) |
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
- `INTERNAL` listener advertised as `kafka:9094` on `crmlab-net` — reserved
  for any future in-compose client; nothing uses it in the first slice.
- `CONTROLLER` on 9093 — never published to the host.

## 5. Volumes and persistence

Named volumes, project-prefixed, created and owned by the `crmlab` Compose
project:

- `crmlab-postgres-data` (service `postgres`): all authoritative CRM data —
  business records, audit log, outbox, migration state.
- `crmlab-kafka-data` (service `kafka`): topic logs and KRaft metadata.
  Persisting this across restarts is required for the "worker restart loses
  nothing" acceptance test.

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

> **WARNING — DESTRUCTIVE.** `down -v` deletes `crmlab-postgres-data`, and
> PostgreSQL is the system of record: every company, contact, interaction,
> task, audit record, and outbox row in your local environment is permanently
> erased, along with all Kafka topic data. There is no undo. Use it only when
> you deliberately want a from-scratch environment, and expect to re-run
> migrations, seeds, and topic initialization afterwards.

Both commands are project-scoped by `-p crmlab` (and by `name: crmlab` in the
compose file), so they can only affect this project's containers, network, and
declared named volumes; unrelated containers, images, networks, and volumes on
the machine are untouched. **Never** use `docker system prune`,
`docker volume prune`, or unscoped `docker rm`/`docker volume rm` for
resetting this project.

## 6. Derived-data recovery: outbox replay (Sprint 0002 deliverable)

Kafka topic data is recoverable *because* Sprint 0002 must ship an explicit
replay procedure — the claim holds only with this tooling in place:

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

This procedure is what makes `down -v` recoverable-by-rebuild for derived
stores while still being destructive for authoritative data (section 5).

## 7. Health checks and startup ordering

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
   slice needs (e.g. `crm.outbox.v1`) with explicit partition and retention
   settings. It must be safe to run repeatedly. Broker auto-creation
   (`auto.create.topics.enable`) is disabled; the topology never relies on
   auto-create.
4. Host processes start after infra is healthy. Sprint 0002 adds an npm script
   (e.g. `npm run dev:wait-infra`) that polls TCP connect on
   `127.0.0.1:${POSTGRES_PORT}` and `127.0.0.1:${KAFKA_PORT}` with a bounded
   timeout; then the developer runs migrations (`npm run db:migrate` or via
   api startup), then api → worker → web.
5. The worker tolerates Kafka being briefly unavailable (bounded retry with
   backoff); at-least-once delivery plus idempotency receipts make late joins
   and reconnects safe.

## 8. Developer commands (Sprint 0002 — documented, not executed in Sprint 0001)

All lifecycle commands are project-scoped with `-p crmlab` and address Compose
**service** names (`postgres`, `kafka`), never container names.

| Action | Command |
|--------|---------|
| Bring up infra | `docker compose -p crmlab up -d` |
| Tear down, keep data | `docker compose -p crmlab down` |
| Full reset — DESTRUCTIVE, erases authoritative local data (see section 5 warning) | `docker compose -p crmlab down -v` |
| Tail all infra logs | `docker compose -p crmlab logs -f` |
| Tail one service | `docker compose -p crmlab logs -f postgres` |
| psql shell | `docker compose -p crmlab exec postgres psql -U crmlab -d crmlab` |
| Kafka console consumer | `docker compose -p crmlab exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic crm.outbox.v1 --from-beginning` |
| List Kafka topics | `docker compose -p crmlab exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list` |
| Initialize topics (idempotent) | `npm run kafka:init-topics` |
| Start api (host) | `npm run dev --workspace apps/api` |
| Start web (host) | `npm run dev --workspace apps/web` |
| Start worker (host) | `npm run dev --workspace apps/worker` |

The compose file itself (authored in Sprint 0002) must set `name: crmlab` so
the project scope holds even if a developer forgets `-p`.

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
| `AUTH_MODE` | `dev-token` | Auth stub selector. |
| `POSTGRES_USER` | `crmlab` | Dev-only, local-loopback-only credentials; non-secret by construction, hence allowed in `.env.example`. |
| `POSTGRES_PASSWORD` | `crmlab` | Same as above. |
| `POSTGRES_DB` | `crmlab` | |
| `POSTGRES_PORT` | `5432` | Single source of truth (fallback 5433). |
| `KAFKA_PORT` | `9092` | Single source of truth (fallback 9095). |
| `API_PORT` | `3001` | API binds `127.0.0.1` (fallback 3101). |
| `WEB_PORT` | `3000` | Web binds `127.0.0.1` (fallback 3100). |

### Dev-token auth stub guard (frozen decision, documented convention)

The dev-token auth stub **must refuse to start unless `APP_ENV=local` or
`APP_ENV=test`**. Concretely: at boot, if `AUTH_MODE=dev-token` and `APP_ENV`
is anything else (including unset), the api process exits non-zero with an
explicit error before binding its port. There is no override flag. This makes
it impossible to ship the stub to any non-local environment by configuration
drift.

## 10. Acceptance self-check (Sprint 0001)

- No state-mutating docker command is part of any Sprint 0001 setup path; all
  lifecycle commands above are labeled Sprint 0002 documentation.
- Every proposed host port has a recorded FREE/CONFLICTED result (sections 3–4)
  and binds to 127.0.0.1 only.
- Every project-created container, volume, and network name carries the
  `crmlab-` prefix; commands address Compose service names and are `-p crmlab`
  scoped.
- Services are limited to the approved list: PostgreSQL, Apache Kafka, and the
  three host-run TypeScript processes. No Kubernetes, Spark, OpenSearch,
  Temporal, Flink, ClickHouse, MongoDB, DynamoDB, schema registry, or cloud.
- Cost floor: $0, local only.
