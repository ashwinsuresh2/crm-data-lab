# CRM Agent Team Starter

This pack bootstraps an agent-engineered CRM project without committing you to a particular frontend framework, cloud provider, or data-engine replacement.

## Operating model

- **Claude Code is the primary foreman** for planning and implementation orchestration.
- **Codex is the independent inspector** and can also take isolated implementation tasks.
- **Only one agent owns a file path at a time.**
- **Parallel writers use Git worktrees.**
- **Reviewers are read-only.**
- **No agent commits directly to `main`.**
- **The first milestone is one complete vertical slice, not a broad feature shell.**

## First vertical slice

1. Sign in.
2. Create a company.
3. Create a contact.
4. Log an interaction.
5. Create a follow-up task.
6. Commit the record, audit entry, and outbox event in one PostgreSQL transaction.
7. Publish the outbox event to ordinary Apache Kafka.
8. Consume it exactly once from the application’s point of view.
9. Show the interaction in the timeline and the task on Home.
10. Prove duplicate delivery and worker restart do not create duplicate reminders.

## Install on Windows

Use PowerShell unless you intentionally choose WSL2.

1. Install Git.
2. Install Docker Desktop.
3. Install Node.js LTS and enable Corepack.
4. Install Claude Code.
5. Install or open ChatGPT/Codex.
6. Create an empty GitHub repository and clone it.
7. Copy this starter pack into the repository root.
8. Commit the starter files before launching parallel worktrees.

## Launch Claude Code

From the repository root:

```powershell
claude
```

Then paste `prompts/BOOTSTRAP_CLAUDE_CODE.txt`.

For the first read-only planning team, paste `prompts/PLANNING_TEAM.txt`. Agent teams are optional and experimental; the prompt also works with parallel read-only subagents. To opt in, merge `.claude/settings.agent-teams.example.json` into `.claude/settings.json` for that planning session.

For the first implementation graph, paste `prompts/FIRST_SPRINT_WORKFLOW.txt`.

## Launch Codex

Open the same repository in Codex, but use it as a read-only reviewer until Claude’s implementation branches are ready. Paste `prompts/BOOTSTRAP_CODEX.txt`.

## Directory guide

- `CLAUDE.md`: persistent project instructions for Claude Code.
- `AGENTS.md`: persistent project instructions for Codex and compatible agents.
- `.claude/agents/`: reusable Claude specialists.
- `.codex/agents/`: reusable Codex specialists.
- `docs/`: source of truth for product, architecture, and decisions.
- `tasks/`: bounded work packets with acceptance criteria.
- `prompts/`: launch prompts for orchestration and review.
- `scripts/`: safe local helper scripts.

## Human approval gates

The human owner must approve:

- Product scope and UX behavior.
- Database and event contracts before implementation fan-out.
- Any new paid vendor or cloud resource.
- Authentication, authorization, encryption, and data-retention decisions.
- Any schema migration that drops or rewrites data.
- Production deployment.
- Any replacement-engine cutover.
