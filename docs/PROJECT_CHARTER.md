# Project Charter

## Product objective

Build a sophisticated, competitive CRM for relationship-driven enterprise selling. The first user is internal, but the architecture must permit external tenants later without a rewrite.

## Infrastructure objective

Use the CRM as a real workload for understanding and comparing event streaming, batch processing, search, storage, workflows, and deployment. Replacement engines enter through stable contracts and begin in shadow mode.

## Product promise

The CRM should automatically preserve relationship history, make next actions explicit, provide excellent pipeline visibility, support strong customization without consultants, and make every automated action explainable and auditable.

## Near-term non-goals

- Rebuilding all of Salesforce.
- Supporting arbitrary custom objects before the standard CRM vertical slice works.
- Cloud Kubernetes.
- Always-on Spark, Flink, ClickHouse, or OpenSearch.
- Production replacement-engine cutovers.
- Multiple microservices.
- Mobile-native applications.

## Foundational invariants

1. PostgreSQL is authoritative.
2. All writes use the CRM API.
3. Business records, audit entries, and outbox events commit atomically.
4. Consumers are idempotent.
5. Search and analytics are derived and rebuildable.
6. Every tenant-owned record and event is explicitly tenant-scoped.
7. External side effects are separated from shadow comparison.
8. Cost floors are documented before services are added.
