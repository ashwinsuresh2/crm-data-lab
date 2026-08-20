# Local Development Topology Contract (Sprint 0001, Node I)

Status: **Documentation only.** This file is the contract for the Docker Compose
topology that Sprint 0002 will implement. **No compose file, container, image,
volume, or network is created by Sprint 0001.** All commands in section 7 are
*documented for Sprint 0002* and were **not executed** while authoring this
contract, except the read-only port checks recorded in section 3.

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
- This machine runs unrelated containers. **Every project resource is
  prefixed `crmlab-`** and all lifecycle commands are scoped with the Compose
  project name `crmlab` so that nothing outside this project is ever touched.

## 2. Topology overview

Two containers in Docker Compose; three Node processes on the host.

| Component        | Runs where                | Name / process                         |
|------------------|---------------------------|----------------------------------------|
| PostgreSQL 16    | Docker Compose            | container `crmlab-postgres`            |
| Apache Kafka     | Docker Compose            | container `crmlab-kafka` (KRaft, 1 node) |
| API (TypeScript modular monolith) | Host, `npm` | `apps/api` dev server     |
| Web (Next.js)    | Host, `npm`               | `apps/web` dev server                  |
| Worker           | Host, `npm`               | `apps/worker` process                  |
| Network          | Docker Compose            | `crmlab-net` (bridge)                  |

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
- A single combined broker+controller node is sufficient for at-least-once,
  durable, replayable local development. Replication factor 1 is acceptable
  because Kafka topics here are rebuildable from the PostgreSQL outbox
  (PostgreSQL is authoritative truth; derived stores are disposable).

### Proposed pinned images (Sprint 0002 implements)

| Service          | Image (pinned)         | Notes                                   |
|------------------|------------------------|-----------------------------------------|
| `crmlab-postgres`| `postgres:16.6`        | Major version 16 frozen for the slice.  |
| `crmlab-kafka`   | `apache/kafka:3.9.1`   | Official Apache image, KRaft-native.    |

(Exact patch versions may be bumped by Sprint 0002 at implementation time, but
must remain pinned — never `latest`.)

## 3. Host ports (checked on this machine, 2026-08-19)

Verification method (read-only): `docker ps -a` (no crmlab or conflicting port
bindings exist; only three stopped unrelated `welcome-to-docker` containers
with no published ports) and `netstat -ano -p TCP` filtered to LISTENING. The
complete set of listening TCP ports at check time was:
`135, 139, 445, 664, 2179, 5040, 16993, 49664, 49665, 49666, 49667, 49668, 49673`.

| Port | Assigned to                              | Published by Compose? | Check result |
|------|------------------------------------------|-----------------------|--------------|
| 5432 | `crmlab-postgres` (PostgreSQL)           | Yes → host 5432       | **FREE**     |
| 9092 | `crmlab-kafka` external listener (host clients) | Yes → host 9092 | **FREE**     |
| 9093 | `crmlab-kafka` KRaft controller listener | **No** (internal to `crmlab-net` only) | **FREE** (not published anyway) |
| 9094 | `crmlab-kafka` internal broker listener (future in-compose clients) | **No** (internal only) | **FREE** (not published anyway) |
| 3000 | `apps/web` Next.js dev server (host process) | n/a (host)        | **FREE**     |
| 3001 | `apps/api` API dev server (host process) | n/a (host)            | **FREE**     |
| —    | `apps/worker`                            | no listening port     | n/a          |

No conflicts found; no alternates needed. If a conflict appears on another
developer machine, the documented fallbacks are: Postgres → 5433, Kafka
external → 9095, web → 3100, api → 3101, overridden via `.env` (section 8),
never by editing the compose file ad hoc.

Kafka listener contract (for Sprint 0002):

- `EXTERNAL` listener advertised as `localhost:9092` — used by host-run api,
  worker, and tests.
- `INTERNAL` listener advertised as `crmlab-kafka:9094` — reserved for any
  future in-compose client; nothing uses it in the first slice.
- `CONTROLLER` on 9093 — never published to the host.

## 4. Volumes and persistence

All named, project-prefixed; created and owned by the `crmlab` Compose project.

| Volume                 | Mounted in        | Persists                                  |
|------------------------|-------------------|-------------------------------------------|
| `crmlab-postgres-data` | `crmlab-postgres` | All authoritative CRM data, migrations state, outbox |
| `crmlab-kafka-data`    | `crmlab-kafka`    | Topic logs + KRaft metadata (survives restarts; required for the "worker restart loses nothing" acceptance test) |

Persistence rules:

- Data survives `docker compose -p crmlab down` and machine reboots.
- Data is destroyed **only** by the explicit reset command below.

### Safe reset (project-scoped; cannot touch non-project containers/volumes)

```
docker compose -p crmlab down -v
```

`-p crmlab` restricts the operation to resources labeled with this Compose
project; `-v` removes only the `crmlab-*` named volumes declared in this
project's compose file. Unrelated containers, images, networks, and volumes on
the machine are untouched. **Never** use `docker system prune`,
`docker volume prune`, or unscoped `docker rm` for resetting this project.

After a reset, a developer re-runs migrations and (optionally) seed scripts;
Kafka topics are recreated by the compose init/app path. Search/analytics are
derived and rebuildable by definition, so a reset is always safe for dev.

## 5. Health checks

| Service           | Health check (compose `healthcheck`)                                | Cadence                    |
|-------------------|---------------------------------------------------------------------|----------------------------|
| `crmlab-postgres` | `pg_isready -U crmlab -d crmlab`                                    | interval 5s, timeout 3s, retries 10 |
| `crmlab-kafka`    | `/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092` | interval 10s, timeout 10s, retries 12, start_period 20s |

Host processes (api, web, worker) expose health in-app:

- `apps/api`: `GET /healthz` returns 200 only when it can reach Postgres.
- `apps/worker`: logs a ready line after Kafka consumer group join; no port.

## 6. Startup ordering

1. `crmlab-postgres` and `crmlab-kafka` start in parallel; each has its own
   health check. They do not depend on each other.
2. Anything later added *inside* Compose must use
   `depends_on: { crmlab-postgres: { condition: service_healthy } }` (and
   likewise for Kafka) — never bare `depends_on`.
3. Host processes are started only after infra is healthy. Sprint 0002 adds an
   npm script (e.g. `npm run dev:wait-infra`) that polls `pg_isready` via TCP
   connect on 5432 and Kafka on 9092 with a bounded timeout, then the developer
   runs api → worker → web. The api runs migrations (or a dedicated
   `npm run db:migrate`) before serving.
4. The worker tolerates Kafka being briefly unavailable (bounded retry with
   backoff) because at-least-once + idempotent consumers make late joins safe.

## 7. Developer commands (Sprint 0002 — documented, not executed in Sprint 0001)

All lifecycle commands are project-scoped with `-p crmlab`.

| Action | Command |
|--------|---------|
| Bring up infra | `docker compose -p crmlab up -d` |
| Tear down (keep data) | `docker compose -p crmlab down` |
| Tear down + wipe project data | `docker compose -p crmlab down -v` |
| Tail all infra logs | `docker compose -p crmlab logs -f` |
| Tail one service | `docker compose -p crmlab logs -f crmlab-postgres` |
| psql shell | `docker compose -p crmlab exec crmlab-postgres psql -U crmlab -d crmlab` |
| Kafka console consumer | `docker compose -p crmlab exec crmlab-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic crm.outbox.v1 --from-beginning` |
| List Kafka topics | `docker compose -p crmlab exec crmlab-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list` |
| Start api (host) | `npm run dev --workspace apps/api` |
| Start web (host) | `npm run dev --workspace apps/web` |
| Start worker (host) | `npm run dev --workspace apps/worker` |

The compose file itself (authored in Sprint 0002) should also set
`name: crmlab` so the project scope holds even if a developer forgets `-p`.

## 8. Environment variable conventions

- The repo commits **`.env.example` only**, with every required variable and a
  safe local default or placeholder. Real `.env` files are gitignored and
  **never committed** (per CLAUDE.md safety rules).
- Each app workspace reads a root `.env` plus optional per-app overrides;
  variables are validated at process start (fail fast on missing/invalid).

Proposed variables for the slice:

| Variable | Local default (in `.env.example`) | Notes |
|----------|-----------------------------------|-------|
| `APP_ENV` | `local` | Environment discriminator: `local` \| `test` \| future values. |
| `AUTH_MODE` | `dev-token` | Auth stub selector. |
| `DATABASE_URL` | `postgresql://crmlab:crmlab@localhost:5432/crmlab` | Dev-only credentials; fine in `.env.example` because they are local-only and non-secret by construction. |
| `KAFKA_BROKERS` | `localhost:9092` | Comma-separated list; the stable client/config boundary for future WarpStream/engine swaps. |
| `API_PORT` | `3001` | |
| `WEB_PORT` | `3000` | |
| `POSTGRES_HOST_PORT` | `5432` | Consumed by the compose file for the host mapping (fallback 5433). |
| `KAFKA_HOST_PORT` | `9092` | Fallback 9095. |

### Dev-token auth stub guard (frozen decision, documented convention)

The dev-token auth stub **must refuse to start unless `APP_ENV=local` or
`APP_ENV=test`**. Concretely: at boot, if `AUTH_MODE=dev-token` and `APP_ENV`
is anything else (including unset), the api process exits non-zero with an
explicit error before binding its port. There is no override flag. This makes
it impossible to ship the stub to any non-local environment by configuration
drift.

## 9. Acceptance self-check (Sprint 0001)

- No state-mutating docker command is part of any Sprint 0001 setup path; all
  lifecycle commands above are labeled Sprint 0002 documentation.
- Every proposed port has a recorded FREE/CONFLICTED result (section 3).
- Every container, volume, and network name carries the `crmlab-` prefix; all
  lifecycle commands are `-p crmlab` scoped.
- Services are limited to the approved list: PostgreSQL, Apache Kafka, and the
  three host-run TypeScript processes. No Kubernetes, Spark, OpenSearch,
  Temporal, Flink, ClickHouse, MongoDB, DynamoDB, schema registry, or cloud.
- Cost floor: $0, local only.
