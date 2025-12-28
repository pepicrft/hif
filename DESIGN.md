# hif - Design

This document captures the design decisions for hif, a version control system built for an agent-first world.

## Philosophy

Git was designed for human collaboration: batch work into commits, review in PRs, merge branches. But agents work differently. They explore, backtrack, try alternatives, and reason through decisions. hif is designed from the ground up for this reality.

**Key principles:**

- Many concurrent agents (local and remote) doing the work
- Humans reviewing the output
- Concurrency is the norm, not the exception
- No git compatibility - this replaces git entirely
- Portability matters - hif works fully offline, forges are optional

## Core Concepts

### No commits, no branches, no PRs

These are git concepts for human workflows. hif doesn't have them.

Instead, hif has:

| Concept | Description |
|---------|-------------|
| Operation stream | Continuous record of everything that happens |
| Patch | A unit of work with intent, decisions, conversation, and file changes |
| Main state | The current state of the codebase (like trunk, but simpler) |

### Patches

A **patch** is the fundamental unit of work in hif. It encapsulates:

- **Intent** - What the patch is trying to accomplish
- **Decisions** - Why things were done a certain way
- **Conversation** - Discussion between agents and humans
- **File changes** - The actual modifications to the codebase
- **State** - Open, applied, or abandoned

When you open a patch, you get a working copy of the codebase at that point. Agents work in that copy. When the patch is applied, changes merge into the main state.

```
Patch: "Add authentication"
├── Intent: Add login/logout to the API
├── Decisions
│   ├── "Using JWT because human specified"
│   └── "Put auth middleware in /middleware - existing pattern"
├── Conversation
│   ├── Human: "We need login with email"
│   ├── Agent: "Should I use JWT or sessions?"
│   └── Human: "JWT"
├── File changes
│   └── (stream of operations on files)
└── State: applied
```

### Conflict Resolution

Since patches have their own working copies, conflicts happen at apply time:

```
Main state: version 100

Patch A opens (copy of version 100)
  Agent A works...

Patch B opens (copy of version 100)
  Agent B works...

Patch A applies -> Main state: version 101
Patch B tries to apply -> Conflict (B was based on 100, main is now 101)
```

When a conflict occurs:

1. hif detects the conflict (patch base is outdated)
2. An agent is spawned to resolve it
3. The resolving agent sees:
   - What both patches were trying to do (intent, decisions, conversation)
   - The actual file conflicts
4. Agent produces a resolution
5. Human reviews if needed

The resolving agent can open its own patch ("Resolve conflict between Patch A and Patch B") for full traceability.

## Architecture Split

### hif (the tool)

Local, portable, the source of truth.

- Operation stream (every edit recorded)
- Patches (including state, decisions, conversation)
- Full history
- Conflict detection
- File state management
- `.hif/` directory structure (like `.git/`)

hif works completely offline. You can use it without any forge.

### micelio.dev (the forge)

Collaboration layer, optional.

- Multi-user access control
- Agent orchestration (spawning agents, coordinating work)
- Conflict resolution (spawns agents when patches conflict)
- Notifications, dashboards
- Discovery (find projects, contributors)
- Hosted agents

The forge adds collaboration features on top of hif, but all data lives in hif itself. You can move a hif repository between forges, or use no forge at all.

## Storage

hif uses a `.hif/` directory (like git uses `.git/`).

Open question: file-based storage vs SQLite.

| Approach | Pros | Cons |
|----------|------|------|
| Files | Simple, transparent, debuggable, no dependencies | Many concurrent agents writing may cause issues |
| SQLite | Atomic transactions, queries, concurrent access, single file | Corruption can kill whole database, opaque |

Given the concurrent agent use case, SQLite may be the better choice. But this needs more exploration.

## Open Questions

### Provenance and Context

How does hif track *why* changes were made?

- The patch captures intent and decisions
- But how granular? Per-file? Per-line? Per-operation?
- How does this surface in the UI/CLI?

### Agent Protocol

How do agents interact with hif?

- CLI commands? Library API? Protocol?
- How do agents record reasoning/decisions?
- Is there a standard format for agent actions?

### Checkpoints

Should hif have automatic checkpoints in the operation stream?

- When tests pass?
- When an agent completes a sub-task?
- User-defined triggers?

### Vocabulary

Commands and terminology:

- `hif init` - Initialize a repository
- `hif patch open "description"` - Start a new patch
- `hif patch apply` - Apply a patch to main
- `hif status` - Show current state
- What else?

---

*This is a living document. Update as decisions are made.*
