# Sprint 0001: Contract-First Vertical Slice

## Goal

Freeze the observable product, domain, API, event, and local-development contracts required for the first vertical slice. No broad product implementation begins until the contract review passes.

## Fan-out nodes

### Node P: Product behavior

- Owner: product-spec agent
- Writes: `docs/specs/product-behavior.md`
- Output: screens, interactions, edge cases, acceptance criteria

### Node D: Domain and data

- Owner: backend/data-design agent
- Writes: `docs/specs/domain-model.md`, `docs/specs/database-contract.md`
- Output: objects, relationships, transaction boundary, tenant rules

### Node E: Event contract

- Owner: data-platform agent
- Writes: `docs/specs/event-contract.md`
- Output: topic, envelope, partition key, consumer behavior, replay/idempotency rules

### Node U: UX architecture

- Owner: frontend/product agent
- Writes: `docs/specs/ux-architecture.md`
- Output: page map, states, primary workflows, responsive behavior

### Node I: Local topology

- Owner: infra agent
- Writes: `docs/specs/local-topology.md`
- Output: containers, ports, volumes, health checks, commands, cost = local only

## Barrier review

A lead agent synthesizes the five contracts and identifies conflicts. No code is written until the human approves the frozen version.

## Verification

- Product verifier checks every requirement is observable.
- Security verifier checks tenant and authorization assumptions.
- Architecture verifier checks low-idle-cost and replacement boundaries.
