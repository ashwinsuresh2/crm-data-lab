# Sprint 0001 — Wave-1 Barrier Review: Architecture Lens

- **Reviewed commit:** `1c4dd59` on `sprint-0001-contracts` (2026-08-20)
- **Reviewer:** architecture-reviewer agent (read-only)
- **Documents:** docs/specs/* against CLAUDE.md and docs/PROJECT_CHARTER.md

---

## Question E — Answers with text-level fixes

### E1. Remove the `container_name` pins? — Yes, remove them.

**What pinning adds:** only removal of the `-1` suffix in `docker ps` output. The doc itself establishes the pinned names are otherwise unused: §2 says "Commands never address container names" and §8 repeats it. Since §8 mandates `name: crmlab`, the default names are already `crmlab-postgres-1` / `crmlab-kafka-1` — the `crmlab-` prefix requirement is satisfied with zero pinning.

**What pinning costs:** `container_name` is unique per Docker daemon, not per Compose project — defeating the project-scoping story:
- Concrete failure 1 (test isolation): an ephemeral second project (`docker compose -p crmlab-test up -d`) reusing the compose file while the dev stack is up fails hard: `Conflict. The container name "/crmlab-postgres" is already in use`.
- Concrete failure 2 (worktrees): CLAUDE.md orchestration rule 4 mandates worktree-isolated parallel agents; two worktrees bringing up infra concurrently collide on pinned names even with distinct `-p` values.

**Recommended text changes (Node I):** replace the §2 pinning paragraph with a statement that `name: crmlab` yields `crmlab-postgres-1`/`crmlab-kafka-1` and that `container_name` is deliberately not set (daemon-global collision); rename the §2 table column to "Default container name"; update the §10 self-check to "carries the `crmlab` project prefix via `name: crmlab` (no hard-pinned container_name)."

**Related (same defect class, Finding F3):** hard-pinned volume names `crmlab-postgres-data`/`crmlab-kafka-data` and network `crmlab-net` have the identical daemon-global problem — worse for volumes: a `crmlab-test` project declaring the same pinned volume name would *silently attach to the dev project's authoritative data*, and its `down -v` would destroy it. Use project-relative defaults (Compose derives `crmlab_postgres-data` automatically from `name: crmlab`).

### E2. Does §6 condition the replay claim on PostgreSQL surviving? — Not explicitly; flagged.

§6 step 1 implicitly requires a surviving outbox, but the precondition is never stated. Worse, §6's final sentence ties replay to the one scenario where PostgreSQL does *not* survive: "This procedure is what makes `down -v` recoverable-by-rebuild for derived stores while still being destructive for authoritative data." After `down -v` the outbox and receipts are gone; there is nothing to replay — Kafka is not "recovered," it is empty because the source of truth is empty. §2's KRaft rationale carries the same unconditioned claim.

**Recommended text changes (Node I):** first line of §6: *"Precondition: replay reconstructs Kafka only from a surviving PostgreSQL outbox. If the postgres volume is lost, there is no outbox to replay; PostgreSQL survival is the sole recovery anchor."* Replace the final §6 sentence: replay applies after Kafka-only data loss; it does **not** apply after `down -v`, which destroys the outbox itself — after `down -v` there is nothing to replay, only a fresh seeded environment to rebuild. Append the survival precondition to the §2 KRaft bullet.

### E3. Does the doc admit `down -v` is unrecoverable without a backup? — Mostly; one contradicting sentence; flagged.

§5's WARNING is strong and §8's table row labels it destructive. Two gaps: (1) the §6 "recoverable-by-rebuild" sentence undercuts §5 — fix per E2; (2) §5 never says "backup" or that no backup mechanism exists in this slice. **Recommended §5 addition:** *"No backup or dump procedure exists in this slice; without one you cannot recover historical data after `down -v` — the only after-state is a fresh, empty, re-seeded environment. If local history matters, take a manual `pg_dump` first."*

---

## Findings

**F1 — `container_name` pinning contradicts project scoping and parallel-agent/test workflows.**
Severity: **major**. Contract: local-topology.md §2, §10. Failure example: `docker compose -p crmlab-test up -d` fails with a container-name conflict; likewise two worktree checkouts. Owning node: **I**. Resolution: remove `container_name`; rely on `name: crmlab` defaults; wording in E1.

**F2 — §6 misstates recoverability: replay not conditioned on PostgreSQL survival; `down -v` called "recoverable-by-rebuild".**
Severity: **major**. Contract: local-topology.md §6 (final sentence), §2 (KRaft bullet), §5. Failure example: a developer with meaningful local CRM history runs `down -v` believing "recoverable-by-rebuild," then finds the outbox — the only replay source — destroyed with it. Owning node: **I**. Resolution: precondition + rewritten sentence per E2; backup sentence per E3.

**F3 — Hard-pinned volume and network names share the daemon-global collision defect, with silent-data-sharing risk for volumes.**
Severity: **major** (data-destruction path). Contract: local-topology.md §2 table, §5. Failure example: a second project (`-p crmlab-test`) declaring volume `name: crmlab-postgres-data` attaches to the dev project's authoritative volume; its `down -v` erases dev data despite both commands being "project-scoped." Owning node: **I**. Resolution: project-relative volume names; update §2 table, §5 names, and the §5 claim that `-v` "can only affect this project's declared named volumes" (true only when names are project-derived).

**F4 — §5 lacks an explicit "no backup exists; historical data unrecoverable" statement.**
Severity: minor. Contract: local-topology.md §5 WARNING. Failure example: reader treats "full reset" as an operational reset rather than data loss. Owning node: **I**. Resolution: sentence in E3.

**F5 — Concrete topic name `crm.outbox.v1` leaks the outbox mechanism into the wire contract and pre-commits Node E's naming.**
Severity: minor. Contract: local-topology.md §7 item 3 and §8 console-consumer command. Failure example: Sprint 0002 copies `crm.outbox.v1` verbatim; the public topic name encodes an internal persistence mechanism, awkward for future engines with no outbox. Owning node: **I** (E owns the actual name). Resolution: mark the §8 topic illustrative; defer naming to Node E; prefer domain-oriented naming (e.g. `crm.events.v1`).

**F6 — Product contract names Kafka in a user-observable definition.**
Severity: minor. Contract: product-behavior.md §1 ("Outbox event — …later published to Kafka") and §6 preamble. Failure example: product-level acceptance tests phrase assertions as "Kafka publish," coupling product tests to the broker and requiring rewording when WarpStream/Mojo shadow engines arrive — the leak CLAUDE.md's client-boundary rule guards against. The state names (pending/published/processed) are already broker-agnostic; only prose leaks. Owning node: **P**. Resolution: "later published to the event stream (Kafka in this slice)."

**No findings** on: the three-step outbox lease protocol (claim with `FOR UPDATE SKIP LOCKED` lease → publish outside any transaction → short ack; correct at-least-once semantics, crash-safe via lease expiry, no lock across the network call, engine-agnostic — WarpStream or a future Mojo engine drops in behind Node E's client boundary; the absence of a `claimed_by` guard on ack is harmless duplicate-publish absorbed by consumer receipts *(note: the data-correctness lens examined this more adversarially and found metadata/status corruption — see its report; delivery-loss assessment here still stands)*); technology-list compliance (no ZooKeeper, no schema registry, no excluded services); open formats; modular-monolith boundary; tenant isolation (composite FKs incl. membership-targeted actor FKs); authoritative-vs-derived separation; observability posture; idle cost ($0, loopback-only, zero when down); `/readyz` not gated on Kafka preserving the Postgres-only synchronous write path.

## Verdict

Freeze-ready after text-only edits: the architecture (seams, outbox protocol, isolation, derived-data posture) is sound, but §5/§6 recoverability wording (F2/F4) and the daemon-global name pins (F1/F3) must be corrected before Sprint 0002 implements from the doc.
