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

## Core Concept: Sessions

hif has one concept: **sessions**.

A session is a bounded unit of work - exactly what happens when you or an agent work on something. It captures:

- 🎯 **Goal** - what you're trying to accomplish
- 💬 **Conversation** - discussion between agents and humans
- 🧠 **Decisions** - why things were done a certain way
- 📝 **Changes** - the actual file modifications
- 📊 **State** - open, landed, or abandoned

```
Session: "Add authentication"
├── Goal: Add login/logout to the API
├── Conversation
│   ├── Human: "We need login with email"
│   ├── Agent: "Should I use JWT or sessions?"
│   └── Human: "JWT"
├── Decisions
│   ├── "Using JWT because human specified"
│   └── "Put auth middleware in /middleware - existing pattern"
├── Changes
│   └── [file operations...]
└── State: landed
```

### Why sessions?

The term comes from how coding agents actually work. When Claude Code or Codex work on a task, they operate in a session: a goal, a conversation, reasoning, and file changes. hif stores exactly this.

Sessions work for:
- **Local work** - you and an agent on your machine
- **Remote work** - an agent running on a server
- **Parallel work** - multiple agents working simultaneously
- **Nested work** - a session can spawn sub-sessions

### Session lifecycle

```bash
hif session start "Add authentication"   # start working
# ... work happens, files change ...
hif session land                         # changes go to main
```

**States:**
- `open` - work in progress
- `landed` - changes integrated into main
- `abandoned` - discarded

### Landing sessions

When you `land` a session, its changes become part of main. If there are conflicts (another session landed first), hif detects them and helps resolve.

```
Session A: "Add auth"                    Main
    │                                      │
    │  [changes]                           │
    │                                      │
    └─────────── hif session land ────────→│
                                           │
                                        [now includes auth]
```

## CLI

```bash
hif init                              # initialize repository
hif session start "description"       # start a new session
hif session list                      # list all sessions
hif session status                    # current session details
hif session land                      # integrate changes to main
hif session abandon                   # discard session
hif goto <session>                    # navigate to a session's state
```

## Navigation

Sessions are the unit of navigation. You can go to any session's state:

```bash
hif goto main                         # current main state
hif goto session:abc123               # state after session landed
hif goto session:abc123~1             # state before that session
```

Labels can point to sessions for convenience:

```bash
hif label "v1.0" session:abc123       # name a session
hif goto v1.0                         # go to labeled session
```

## Conflict Resolution

Since sessions have their own working state, conflicts happen at land time:

```
Main state: version 100

Session A starts (copy of version 100)
  Agent A works...

Session B starts (copy of version 100)
  Agent B works...

Session A lands -> Main state: version 101
Session B tries to land -> Conflict (B was based on 100, main is now 101)
```

When a conflict occurs:

1. hif detects the conflict (session base is outdated)
2. An agent can be spawned to resolve it
3. The resolving agent sees:
   - What both sessions were trying to do (goals, decisions, conversation)
   - The actual file conflicts
4. Resolution happens in its own session for traceability

## Architecture Split

### hif (the tool)

Local, portable, the source of truth.

- Sessions (including state, decisions, conversation)
- File changes within sessions
- Full history
- Conflict detection
- `.hif/` directory structure

hif works completely offline. You can use it without any forge.

### micelio.dev (the forge)

Collaboration layer, optional.

- Multi-user access control
- Agent orchestration (spawning agents, coordinating work)
- Conflict resolution (spawns agents when sessions conflict)
- Notifications, dashboards
- Discovery (find projects, contributors)
- Hosted agents

The forge adds collaboration features on top of hif, but all data lives in hif itself. You can move a hif repository between forges, or use no forge at all.

## Interfaces and Bindings

hif ships as both:

- A first-class CLI (for humans and agents)
- A native library with stable C bindings, so other languages can integrate directly

The CLI and C API use the same core engine. Other language bindings (Go/Rust/Python/JS) can be thin wrappers over the C API.

Agents interface via the CLI - it's just another tool in the agent's toolbox.

## Storage

hif uses a `.hif/` directory (like git uses `.git/`).

**Decision:** file-based storage for transparency, portability, and recoverability.

### .hif/ Layout

```
.hif/
  sessions/
    <session-id>/
      meta.json           # goal, state, timestamps, owner
      conversation.jsonl  # append-only conversation log
      decisions.jsonl     # append-only decisions log
      ops.jsonl           # append-only file operations
  objects/
    blobs/
      aa/bb/<hash>        # content-addressed file contents
    trees/
      cc/dd/<hash>        # content-addressed directory trees
  main/
    state.json            # current main state reference
    history.jsonl         # append-only landed sessions
  indexes/                # rebuildable
    sessions.idx
    paths.idx
  locks/
```

### Concurrency

Local environments may run multiple agents against the same repository. The storage design handles this:

- **Append-only logs** - sessions write to their own files, no contention
- **Content-addressed objects** - immutable, safe for concurrent reads
- **Atomic operations** - landing a session is atomic
- **Per-session isolation** - each session has its own directory

## Open Questions

### Session nesting

Can sessions contain sub-sessions? If so:
- How deep can nesting go?
- Does landing a parent land all children?
- How does this affect navigation?

### Checkpoints

Should sessions have named checkpoints within them?

```bash
hif checkpoint "tests pass"           # mark a point in the session
hif goto session:abc123@tests-pass    # go to that checkpoint
```

### Provenance granularity

How granular is the "why" tracking?
- Per-session (current)
- Per-file
- Per-line

---

*This is a living document. Update as decisions are made.*
