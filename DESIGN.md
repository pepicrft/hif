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

## Interfaces and Bindings

hif should ship as both:

- A first-class CLI (for humans and agents)
- A native library with stable C bindings, so other languages can integrate directly

The CLI and C API should use the same core engine to avoid divergent behavior. Other language bindings (Go/Rust/Python/JS) can be thin wrappers over the C API.

Agents doing local coding sessions should be able to interface via the CLI as well; the CLI is just another tool in the agent's toolbox.

## Sessions and Collaboration

Sessions are data, not transport. A session is an ordered stream of events (messages, actions, decisions) stored inside hif and attached to a patch + agent id.

Key points:

- Local CLI and web UI both emit the same session events and persist them into hif's store.
- Remote agents can stream events via the forge, but the data ends up in the same local hif log.
- The forge mirrors and orchestrates; it never becomes the source of truth.
- Events carry a per-session sequence number plus timestamps to preserve ordering.
- Session streams are append-only; merges reconcile by session id + sequence.
- Conflicts are first-class session events that can be surfaced locally or on the web.

## Storage

hif uses a `.hif/` directory (like git uses `.git/`).

Decision: file-based storage.

| Approach | Pros | Cons |
|----------|------|------|
| Files | Simple, transparent, debuggable, no dependencies | Many concurrent agents writing may cause issues |
| SQLite | Atomic transactions, queries, concurrent access, single file | Corruption can kill whole database, opaque |

Despite the concurrency challenges, we prefer files for transparency, portability, and recoverability.

Local environments are expected to run multiple agents against the same repository directory (including agents spawned in local VMs/containers). This raises real concurrent-write requirements for the `.hif/` store, so we need explicit append-only streams, atomic writes, and well-defined locking/compaction semantics.

### Scaling and Monorepo Considerations

Lessons from Git/Mercurial/Jujutsu suggest that file-based storage can scale, but only with careful log segmentation, compaction, and indexing.

Proposed directions:

- **Segmented append-only logs** to keep write contention low and support parallel agents.
- **Rebuildable indexes** for fast path lookups (e.g., file path -> latest op id, patch id -> op list).
- **Content-addressed snapshots** for file/tree states to avoid duplication.
- **Background maintenance** (compaction/GC) so foreground edits stay fast.
- **Sparse materialization** of working copies to avoid full tree reads in mono-repos.

### Proposed .hif/ Layout (File-Based)

Concrete, scalable layout with append-only streams and rebuildable indexes:

```
.hif/
  ops/
    patch/
      <patch-id>/
        ops-0001.bin
        ops-0002.bin
  patches/
    <patch-id>/
      meta.jsonl
      state.jsonl
      intent.txt
      decisions.jsonl
      conversation.jsonl
  sessions/
    <session-id>.jsonl
  objects/
    blobs/
      aa/bb/<hash>
    trees/
      cc/dd/<hash>
  indexes/            (rebuildable)
    paths.idx         (path -> latest op id)
    patches.idx       (patch id -> op list)
    sessions.idx      (session id -> offsets)
  locks/
    compaction.lock
```

Notes:

- `ops-XXXX.bin` are append-only segments; roll over by size/time to cap file size.
- Patch metadata is append-only; current state is the last event in `state.jsonl`.
- `objects/` stores content-addressed blobs/trees for snapshots and sparse checkouts.
- `indexes/` are derived and can be rebuilt from ops + patch metadata.

### Write and Compaction Rules

- **Atomic appends:** write a framed binary record (length + payload) in a single append; fsync on boundaries.
- **Segment rollover:** create a new `ops-XXXX.bin` when size limit is reached.
- **No global locks:** normal operations avoid global locks; per-segment locks are acceptable.
- **Compaction:** background process merges old segments into packed segments and rebuilds indexes.
- **Recovery:** if indexes are missing or corrupt, rebuild from ops + patch metadata.

### Binary Operation Record Format (Draft)

Each ops segment starts with a file header, followed by framed records.

**File header (fixed):**

- Magic: `HIFOPLOG` (8 bytes)
- Version: u16 (little-endian)
- Reserved: u16

**Record frame (fixed header + payload + CRC):**

- Record length: u32 (little-endian), length of header+payload (not including CRC)
- Record type: u8
- Record version: u8
- Flags: u16
- Timestamp: u64 (unix nanos)
- Agent id: 16 bytes (UUID)
- Patch id: 16 bytes (UUID)
- Payload: `record_length - header_size` bytes
- CRC32: u32 of header+payload

Record type defines the payload encoding (e.g., file op, intent, decision, checkpoint). Payloads can be TLV or msgpack for flexibility; we can finalize once the op taxonomy is settled.

### Minimal Record Types (Draft)

Keep the taxonomy small and extensible; add types only when needed.

- `file_op`: create/modify/delete a file; payload includes path + content reference.
- `patch_state`: open/applied/abandoned; payload includes new state.
- `intent`: patch intent text.
- `decision`: decision text + optional references.
- `conversation`: session message (human/agent).
- `checkpoint`: labeled milestone (e.g., tests pass).

Payload schemas can be messagepack maps keyed by short field names to keep binary size down.

## Design Threads (WIP)

This section captures the next design decisions we need to converge on. It is intentionally concrete so we can validate the model early.

### Operation Stream Model

We should treat the operation stream as the authoritative log, with patches as metadata layered on top.

Draft model:

- Every edit is an append-only operation with timestamp, author/agent id, patch id, and file path.
- Operations are the source of truth for file state; snapshots are derived.
- Patches are logical groupings that reference operations by id.

Open questions:
- Should the stream be per-repo or per-branch-of-history?
- Do we need operations for "intent/decision/conversation", or store those separately on the patch?

### Patch Lifecycle and Working Copies

We need a consistent rule for materializing working copies:

- Opening a patch creates a working copy at a specific main state version.
- The working copy is "detached"; it only moves when the user/agent explicitly rebases or applies.
- Patch apply is a merge operation against main state; conflicts are recorded as part of that patch.

We should define whether a patch can be partially applied (e.g., select files or operations) or is all-or-nothing. My current bias is all-or-nothing to preserve traceability.

### Conflict Resolution Semantics

When a patch apply conflicts, we should:

1. Record a conflict event on the patch (with references to the conflicting operations).
2. Spawn a resolver agent into a new patch whose intent is "Resolve conflict between X and Y".
3. Require the resolver patch to apply cleanly before the original patch can be applied.

This maintains an explicit chain of reasoning and avoids "hidden" manual merges.

### Storage Direction (Decision)

Given concurrency, we will keep storage file-based with a sharded, append-only design:

- The operation log is append-only and sharded (e.g., per-agent or per-patch streams).
- Patch metadata lives in its own file stream, referencing operation ids.
- Materialized working copies live in a working directory; indices are derived and can be rebuilt.

We can use file locks for compaction and indexing, but normal operation should avoid global locks.

### Agent Protocol (Minimal Draft)

We should support both CLI and library usage, but the protocol should be the same:

- Agents write to hif via a small command set (open patch, record intent, record decision, apply operations).
- Each agent action produces an operation or patch metadata update so it is fully traceable.
- "Agent id" is a required field; human actions are just agent actions with a human id.

We need to define a canonical wire format for this (JSON lines is a simple starting point).

### Checkpoints

We can introduce optional checkpoints in the operation stream:

- `checkpoint:test-pass` with a name and command output hash.
- `checkpoint:milestone` with human-defined labels.

Checkpoints are helpful for UI but should not change patch semantics.

### Vocabulary Updates

Add CLI verbs for explicit traceability:

- `hif decision add "text"` (patch-scoped)
- `hif intent set "text"` (patch-scoped, overwrite)
- `hif checkpoint add "label"`
- `hif conflict list` (shows unresolved conflicts per patch)

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

## Open Decisions (Candidates)

These are areas where we should explore options before committing to a design.

### Patch Apply Semantics

Options:

- **All-or-nothing apply** (simple, consistent traceability)
- **Partial apply** (by operation/file, more flexible)
- **Split-on-apply** (auto-split into applied + remainder patches)

### Patch Rebase Behavior

Options:

- **No rebase**; resolve conflicts only at apply time
- **Explicit rebase command** for patches
- **Auto-rebase on apply** (more magic, less predictable)
