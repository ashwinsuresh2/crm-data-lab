# First Vertical Slice

## User story

As a salesperson, I can create a company and contact, log a call, state its outcome, and schedule a follow-up. The system records a complete timeline, creates exactly one task, publishes a durable event, and remains correct through duplicate requests and worker restarts.

## Required objects

- Tenant
- User
- Membership
- Company
- Contact
- Interaction
- Task
- Audit event
- Outbox event

## Synchronous behavior

When the user submits an interaction:

1. Authenticate the user.
2. Resolve tenant membership.
3. Authorize access to the contact.
4. Validate outcome and follow-up input.
5. In one PostgreSQL transaction:
   - Insert the interaction.
   - Update the contact’s last-contacted timestamp.
   - Create the follow-up task.
   - Append the audit record.
   - Append the outbox event.
6. Return the interaction and task IDs.

## Asynchronous behavior

1. Publish the outbox event to Apache Kafka.
2. A consumer reads the event.
3. Duplicate delivery must not create another task or reminder record.
4. After a consumer restart, processing resumes without losing the event.
5. Mark or record processing state so the complete path is inspectable.

## Acceptance criteria

- A user can complete the journey from the web interface.
- Unauthorized users cannot read or mutate another tenant’s contact.
- A duplicate HTTP request with the same idempotency key produces one interaction and one task.
- A duplicate Kafka event produces no duplicate business side effect.
- Killing and restarting the worker does not lose the event.
- The contact timeline shows the interaction.
- Home shows the open follow-up task.
- The audit view identifies actor, tenant, action, record, and time.
- Automated tests prove the above.
