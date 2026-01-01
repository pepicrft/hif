# hif - Design

A version control system for an agent-first world, designed for Google/Meta scale.

## Philosophy

Git was designed for human collaboration at small-to-medium scale. But the future is different:

- **Hundreds of AI agents** working concurrently on the same codebase
- **Millions of files** in monorepos
- **Tens of thousands of changes per day**
- **Humans reviewing**, not writing most code

hif is designed for this reality. It takes lessons from [Google's Piper/CitC](https://cacm.acm.org/research/why-google-stores-billions-of-lines-of-code-in-a-single-repository/) and [Meta's Sapling/EdenFS](https://engineering.fb.com/2022/11/15/open-source/sapling-source-control-scalable/), but reimagines them for an agentic world.

**Key principles:**

- **Forge-first** - the server is the source of truth, not local disk
- **Agent-native** - sessions capture goal, reasoning, and changes together
- **Infinite scale** - billions of files, millions of commits, thousands of concurrent agents
- **Lazy everything** - fetch only what you need, when you need it
- **Operations scale with your work**, not repository size

---

## Architecture Overview

hif has three components that work together:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                FORGE                                         │
│                      (Elixir, Go, Rust, or any language)                    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      libhif-core (Zig → C ABI)                      │   │
│  │                                                                     │   │
│  │   Prolly Trees · Bloom Filters · Segmented Changelog · HLC · Hash  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                   │ FFI                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      Forge Application                               │   │
│  │                                                                     │   │
│  │   CockroachDB · S3 · Landing Queue · gRPC Server · Auth · Webhooks │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│                               gRPC API                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ TLS + mTLS
                                    │
┌─────────────────────────────────────────────────────────────────────────────┐
│                               CLIENT (Zig)                                   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      libhif-core (native Zig)                       │   │
│  │                                                                     │   │
│  │   Same algorithms, no FFI overhead on client                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                   │                                         │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                  │
│  │   hif CLI     │  │   hif-fs      │  │  Local Cache  │                  │
│  │               │  │  (Phase 2)    │  │               │                  │
│  │ session start │  │               │  │  Blob LRU     │                  │
│  │ session land  │  │  NFS daemon   │  │  Tree cache   │                  │
│  │ decide, log   │  │  Mount point  │  │  Overlay      │                  │
│  └───────────────┘  └───────────────┘  └───────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Language | Runs | Responsibility |
|-----------|----------|------|----------------|
| **libhif-core** | Zig (C ABI) | Anywhere | Algorithms: trees, bloom, changelog, hashing |
| **Forge** | Any (Elixir, Go, etc.) | Cloud | Source of truth, scaling, consensus |
| **hif CLI** | Zig | Local | User/agent interface |
| **hif-fs** | Zig | Local | Virtual filesystem (Phase 2) |

### Why This Split?

**libhif-core exists because:**
- Algorithms are complex (prolly trees, segmented changelog)
- Getting them right is hard (edge cases, correctness)
- Performance matters (hot path operations)
- Write once, use in any language

**Forge is separate because:**
- Different deployment (cloud vs local)
- Different language strengths (Elixir for concurrency, etc.)
- Teams can work in parallel
- Can have multiple forge implementations

**Client is Zig because:**
- Single binary, no runtime
- Low-level control for NFS
- Reuses libhif-core natively (no FFI overhead)
- Fast startup for CLI

---

## libhif-core

The algorithmic core, shared between forge and client.

### C API

```c
// hif_core.h

#include <stdint.h>
#include <stddef.h>

// Allocator (caller provides memory management)
typedef struct {
    void* (*alloc)(void* ctx, size_t size);
    void (*free)(void* ctx, void* ptr, size_t size);
    void* ctx;
} HifAllocator;

// ============================================================================
// Content Hashing (Blake3)
// ============================================================================

// Hash a blob, returns 32-byte hash
void hif_hash_blob(const uint8_t* data, size_t len, uint8_t out[32]);

// Chunked hashing for large files
typedef struct HifChunker HifChunker;

HifChunker* hif_chunker_new(HifAllocator* alloc, size_t target_chunk_size);
void hif_chunker_free(HifChunker* chunker);

// Returns number of chunks, fills hashes array
size_t hif_chunker_chunk(
    HifChunker* chunker,
    const uint8_t* data,
    size_t len,
    uint8_t (*hashes)[32],
    size_t max_chunks
);

// ============================================================================
// Bloom Filters
// ============================================================================

typedef struct HifBloom HifBloom;

// Create bloom filter for n items with false positive rate fp_rate
HifBloom* hif_bloom_new(HifAllocator* alloc, size_t n, double fp_rate);
void hif_bloom_free(HifBloom* bloom);

void hif_bloom_add(HifBloom* bloom, const uint8_t* data, size_t len);
int hif_bloom_check(const HifBloom* bloom, const uint8_t* data, size_t len);
int hif_bloom_intersects(const HifBloom* a, const HifBloom* b);

// Serialization
size_t hif_bloom_serialized_size(const HifBloom* bloom);
void hif_bloom_serialize(const HifBloom* bloom, uint8_t* out);
HifBloom* hif_bloom_deserialize(HifAllocator* alloc, const uint8_t* data, size_t len);

// ============================================================================
// Prolly Trees (content-addressed B-trees)
// ============================================================================

typedef struct HifTree HifTree;
typedef struct HifTreeDiff HifTreeDiff;

HifTree* hif_tree_new(HifAllocator* alloc);
void hif_tree_free(HifTree* tree);

// Mutations (returns new tree, original unchanged)
HifTree* hif_tree_insert(const HifTree* tree, const char* path, const uint8_t hash[32]);
HifTree* hif_tree_delete(const HifTree* tree, const char* path);

// Queries
int hif_tree_get(const HifTree* tree, const char* path, uint8_t out[32]);
void hif_tree_hash(const HifTree* tree, uint8_t out[32]);

// Diffing
HifTreeDiff* hif_tree_diff(const HifTree* a, const HifTree* b);
void hif_tree_diff_free(HifTreeDiff* diff);

typedef struct {
    const char* path;
    uint8_t old_hash[32];  // zero if added
    uint8_t new_hash[32];  // zero if deleted
} HifDiffEntry;

size_t hif_tree_diff_count(const HifTreeDiff* diff);
const HifDiffEntry* hif_tree_diff_get(const HifTreeDiff* diff, size_t index);

// Serialization
size_t hif_tree_serialized_size(const HifTree* tree);
void hif_tree_serialize(const HifTree* tree, uint8_t* out);
HifTree* hif_tree_deserialize(HifAllocator* alloc, const uint8_t* data, size_t len);

// ============================================================================
// Hybrid Logical Clock
// ============================================================================

typedef struct {
    int64_t physical;   // milliseconds since epoch
    uint32_t logical;   // logical counter
    uint32_t node_id;   // node identifier
} HifHLC;

void hif_hlc_init(HifHLC* hlc, uint32_t node_id);
void hif_hlc_now(HifHLC* hlc, int64_t wall_time);
void hif_hlc_update(HifHLC* hlc, const HifHLC* received, int64_t wall_time);
int hif_hlc_compare(const HifHLC* a, const HifHLC* b);

void hif_hlc_serialize(const HifHLC* hlc, uint8_t out[16]);
void hif_hlc_deserialize(const uint8_t data[16], HifHLC* out);

// ============================================================================
// Segmented Changelog (ancestry queries)
// ============================================================================

typedef struct HifChangelog HifChangelog;

HifChangelog* hif_changelog_new(HifAllocator* alloc);
void hif_changelog_free(HifChangelog* cl);

// Add a session with its parent positions
void hif_changelog_add(
    HifChangelog* cl,
    int64_t position,
    const uint8_t session_id[16],
    const int64_t* parent_positions,
    size_t parent_count
);

// Queries
int hif_changelog_is_ancestor(const HifChangelog* cl, int64_t ancestor, int64_t descendant);
int64_t hif_changelog_common_ancestor(const HifChangelog* cl, int64_t a, int64_t b);

// Serialization
size_t hif_changelog_serialized_size(const HifChangelog* cl);
void hif_changelog_serialize(const HifChangelog* cl, uint8_t* out);
HifChangelog* hif_changelog_deserialize(HifAllocator* alloc, const uint8_t* data, size_t len);
```

### Usage from Elixir (via Zigler)

```elixir
defmodule Hif.Core do
  use Zig, otp_app: :hif_forge, sources: ["c_src/libhif_core.a"]

  # Bloom filters
  def bloom_new(n, fp_rate), do: :erlang.nif_error(:not_loaded)
  def bloom_add(bloom, data), do: :erlang.nif_error(:not_loaded)
  def bloom_check(bloom, data), do: :erlang.nif_error(:not_loaded)
  def bloom_intersects(a, b), do: :erlang.nif_error(:not_loaded)

  # Trees
  def tree_new(), do: :erlang.nif_error(:not_loaded)
  def tree_insert(tree, path, hash), do: :erlang.nif_error(:not_loaded)
  def tree_hash(tree), do: :erlang.nif_error(:not_loaded)
  def tree_diff(a, b), do: :erlang.nif_error(:not_loaded)

  # Hashing
  def hash_blob(data), do: :erlang.nif_error(:not_loaded)
end

defmodule Hif.ConflictDetector do
  alias Hif.Core

  def check(session, landed_since_base) do
    our_bloom = session.bloom_filter

    Enum.find_value(landed_since_base, fn landed ->
      if Core.bloom_intersects(our_bloom, landed.bloom_filter) do
        find_actual_conflicts(session.paths, landed.paths)
      end
    end)
  end
end
```

### Usage from Go

```go
// #cgo LDFLAGS: -lhif_core
// #include <hif_core.h>
import "C"
import "unsafe"

type Tree struct {
    ptr *C.HifTree
}

func NewTree() *Tree {
    return &Tree{ptr: C.hif_tree_new(defaultAllocator)}
}

func (t *Tree) Insert(path string, hash [32]byte) *Tree {
    cpath := C.CString(path)
    defer C.free(unsafe.Pointer(cpath))
    newPtr := C.hif_tree_insert(t.ptr, cpath, (*C.uint8_t)(&hash[0]))
    return &Tree{ptr: newPtr}
}

func (t *Tree) Hash() [32]byte {
    var out [32]byte
    C.hif_tree_hash(t.ptr, (*C.uint8_t)(&out[0]))
    return out
}
```

---

## Core Concept: Sessions

hif has one concept: **sessions**.

A session captures everything about a unit of work:

```
Session: "Add authentication"
├── id: "ses_7f3a2b1c"
├── goal: "Add JWT-based login/logout to the API"
├── owner: "agent_claude_4a2f"
├── base: tree_hash_abc123       # snapshot session started from
├── state: open | landed | abandoned | conflicted
├── conversation:
│   ├── [human]: "We need login with email"
│   ├── [agent]: "Should I use JWT or sessions?"
│   └── [human]: "JWT"
├── decisions:
│   ├── "Using JWT because human specified"
│   └── "Put auth middleware in /middleware - existing pattern"
├── operations:                   # append-only log
│   ├── write src/auth/login.ts <hash>
│   ├── write src/auth/logout.ts <hash>
│   └── modify src/middleware/index.ts <hash>
├── bloom_filter: <paths touched>
└── timestamps:
    ├── created: HLC(1704067200, 0, node_a)
    └── updated: HLC(1704068400, 3, node_a)
```

### Why Sessions?

Sessions match how AI agents actually work. When Claude Code works on a task:
1. It has a **goal** (the user's request)
2. It has a **conversation** (back-and-forth with human)
3. It makes **decisions** (reasoning about approach)
4. It performs **operations** (file changes)

hif stores exactly this structure. The session IS the commit, the PR, and the conversation - unified.

### Session Lifecycle

```
                    ┌──────────────────┐
                    │   session start  │
                    │   (goal, owner)  │
                    └────────┬─────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │      OPEN        │◄────────┐
                    │                  │         │
                    │  - record ops    │         │ resolve
                    │  - add decisions │         │ conflict
                    │  - conversation  │         │
                    └────────┬─────────┘         │
                             │                   │
              ┌──────────────┼──────────────┐    │
              │              │              │    │
              ▼              ▼              ▼    │
     ┌─────────────┐ ┌─────────────┐ ┌──────────┴──┐
     │   LANDED    │ │  ABANDONED  │ │  CONFLICTED │
     │             │ │             │ │             │
     │  changes    │ │  discarded  │ │  needs      │
     │  integrated │ │             │ │  resolution │
     └─────────────┘ └─────────────┘ └─────────────┘
```

### Landing

Landing integrates a session's changes:

1. **Atomic** - all changes land together or none do
2. **Ordered** - global position number via consensus
3. **Non-blocking** - conflicts are recorded, not fatal

```bash
$ hif session land

Landing session ses_7f3a2b1c...
Position in queue: 3
Waiting for consensus...
Landed at position 847293
```

If conflicts are detected:

```bash
$ hif session land

Landing session ses_7f3a2b1c...
Conflict detected with ses_2d4e6f8a (landed 3s ago)
  Conflicting paths:
    - src/middleware/index.ts

Session marked CONFLICTED.
Resolve with: hif session resolve
```

---

## Forge Architecture

The forge is the source of truth. Everything else is cache.

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                           FORGE                                  │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │  Metadata   │  │   Object    │  │  Landing    │             │
│  │  Database   │  │   Store     │  │   Queue     │             │
│  │             │  │             │  │             │             │
│  │ CockroachDB │  │  S3 + CDN   │  │   Raft      │             │
│  │ (sessions,  │  │  (blobs)    │  │  consensus  │             │
│  │  trees,     │  │             │  │             │             │
│  │  indexes)   │  │             │  │             │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│         │               │               │                       │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                     libhif-core                          │  │
│  │           (via FFI: Zigler, cgo, PyO3, etc.)            │  │
│  └──────────────────────────────────────────────────────────┘  │
│         │               │               │                       │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    gRPC API Server                        │  │
│  │                                                          │  │
│  │   StartSession · LandSession · GetTree · GetBlob · ...  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Database Schema

```sql
-- Sessions
CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    repo_id UUID NOT NULL,
    goal TEXT NOT NULL,
    owner_id UUID NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('open', 'landed', 'abandoned', 'conflicted')),
    base_tree BYTEA NOT NULL,         -- 32 bytes, tree hash
    current_tree BYTEA,               -- 32 bytes, tree hash
    landed_position BIGINT,           -- NULL until landed
    bloom_filter BYTEA,               -- serialized bloom filter
    hlc_created BYTEA NOT NULL,       -- 16 bytes
    hlc_updated BYTEA NOT NULL,       -- 16 bytes
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    INDEX idx_repo_state (repo_id, state),
    INDEX idx_repo_position (repo_id, landed_position),
    INDEX idx_owner (owner_id)
);

-- Operations (append-only)
CREATE TABLE operations (
    id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions(id),
    sequence BIGINT NOT NULL,
    op_type TEXT NOT NULL CHECK (op_type IN ('write', 'delete', 'rename')),
    path TEXT NOT NULL,
    blob_hash BYTEA,                  -- 32 bytes, NULL for delete
    hlc BYTEA NOT NULL,

    UNIQUE (session_id, sequence)
);

-- Path index (which sessions touched which paths)
CREATE TABLE path_index (
    repo_id UUID NOT NULL,
    path TEXT NOT NULL,
    session_id UUID NOT NULL,
    landed_position BIGINT,           -- NULL if not landed yet

    PRIMARY KEY (repo_id, path, session_id),
    INDEX idx_path_position (repo_id, path, landed_position)
);

-- Trees (content-addressed)
CREATE TABLE trees (
    hash BYTEA PRIMARY KEY,           -- 32 bytes
    repo_id UUID NOT NULL,
    data BYTEA NOT NULL,              -- serialized tree
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Ancestry (segmented changelog)
CREATE TABLE ancestry (
    repo_id UUID NOT NULL,
    position BIGINT NOT NULL,
    session_id UUID NOT NULL,
    parent_positions BIGINT[],

    PRIMARY KEY (repo_id, position)
);

-- Decisions (append-only)
CREATE TABLE decisions (
    id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions(id),
    sequence BIGINT NOT NULL,
    content TEXT NOT NULL,
    hlc BYTEA NOT NULL,

    UNIQUE (session_id, sequence)
);

-- Conversation (append-only)
CREATE TABLE conversation (
    id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions(id),
    sequence BIGINT NOT NULL,
    role TEXT NOT NULL,               -- 'human' or 'agent'
    content TEXT NOT NULL,
    hlc BYTEA NOT NULL,

    UNIQUE (session_id, sequence)
);
```

### Object Store

Blobs stored in S3/GCS with CDN:

```
s3://hif-objects/
└── {repo_id}/
    └── blobs/
        └── {hash_prefix}/
            └── {hash}

Object format:
  [4 bytes: magic "HIFB"]
  [4 bytes: uncompressed size]
  [zstd compressed content]

Large files (>4MB) are chunked:
  [4 bytes: magic "HIFC"]
  [4 bytes: chunk count]
  [N x 32 bytes: chunk hashes]
```

### Landing Queue

Processes landings with global ordering:

```
1. Session submits land request
   └── Request enters queue with HLC timestamp

2. Raft leader processes in order
   ├── Acquire position (atomic increment)
   ├── Load session operations
   ├── Check conflicts via bloom filter intersection
   │   ├── If bloom intersects: check actual paths in path_index
   │   └── If conflict: mark CONFLICTED, return
   ├── Apply operations to build new tree
   ├── Store new tree
   ├── Update session: state=landed, landed_position=N
   ├── Update path_index
   ├── Update ancestry
   └── Commit transaction

3. Notify watchers via pub/sub
```

### gRPC API

```protobuf
syntax = "proto3";
package hif.v1;

service HifService {
  // Sessions
  rpc StartSession(StartSessionRequest) returns (Session);
  rpc GetSession(GetSessionRequest) returns (Session);
  rpc LandSession(LandSessionRequest) returns (LandResult);
  rpc AbandonSession(AbandonSessionRequest) returns (Empty);
  rpc ResolveConflict(ResolveConflictRequest) returns (Session);

  // Operations
  rpc RecordOperation(RecordOperationRequest) returns (Empty);
  rpc RecordDecision(RecordDecisionRequest) returns (Empty);
  rpc RecordConversation(RecordConversationRequest) returns (Empty);

  // Content
  rpc GetTree(GetTreeRequest) returns (Tree);
  rpc GetBlob(GetBlobRequest) returns (stream BlobChunk);
  rpc PutBlob(stream BlobChunk) returns (PutBlobResponse);

  // Queries
  rpc ListSessions(ListSessionsRequest) returns (stream Session);
  rpc GetPathHistory(GetPathHistoryRequest) returns (stream PathEvent);
  rpc IsAncestor(IsAncestorRequest) returns (IsAncestorResponse);

  // Streaming
  rpc WatchSession(WatchSessionRequest) returns (stream SessionEvent);
  rpc WatchRepo(WatchRepoRequest) returns (stream RepoEvent);
}
```

---

## Client Architecture

The client is thin. It caches aggressively but trusts the forge.

### Phase 1: CLI Only

```
┌─────────────────────────────────────────────────────────────────┐
│                         hif CLI                                  │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   Session   │  │    gRPC     │  │    Local    │             │
│  │   Manager   │  │   Client    │  │    Cache    │             │
│  │             │  │             │  │             │             │
│  │ start/land  │  │ forge comms │  │ blobs/trees │             │
│  │ operations  │  │ streaming   │  │ LRU evict   │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│         │               │               │                       │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                     libhif-core                          │  │
│  │              (native Zig, no FFI overhead)              │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Files accessed via explicit commands:

```bash
$ hif cat src/auth/login.ts       # Fetch and print blob
$ hif write src/auth/login.ts     # Write from stdin
$ hif edit src/auth/login.ts      # Fetch, open in $EDITOR, write back
```

### Phase 2: Virtual Filesystem

```
┌─────────────────────────────────────────────────────────────────┐
│                        hif-fs daemon                             │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │    NFS      │  │   Session   │  │    Cache    │             │
│  │   Server    │  │   Overlay   │  │   Manager   │             │
│  │             │  │             │  │             │             │
│  │ localhost   │  │ local edits │  │ blob/tree   │             │
│  │ :2049       │  │ pre-land    │  │ LRU + pin   │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │
         │ mount
         ▼
┌─────────────────────────────────────────────────────────────────┐
│  ~/repos/myproject/                                             │
│  ├── src/                      ← tree from forge                │
│  │   └── auth/                                                  │
│  │       └── login.ts          ← blob fetched on read          │
│  └── package.json              ← cached locally                 │
└─────────────────────────────────────────────────────────────────┘
```

NFS operations:

| NFS Op | hif-fs behavior |
|--------|-----------------|
| LOOKUP | Return inode from cached tree |
| READDIR | List tree children |
| READ | Fetch blob from cache or forge |
| WRITE | Write to session overlay |
| CREATE | Record operation, write overlay |
| REMOVE | Record delete operation |

---

## CLI Reference

```bash
# Setup
hif auth login                    # Authenticate with forge
hif clone <repo>                  # Initialize local state

# Sessions
hif session start "goal"          # Start new session
hif session status                # Current session info
hif session list                  # List sessions
hif session land                  # Land current session
hif session abandon               # Abandon current session
hif session resolve               # Resolve conflicts
hif session claim <id>            # Claim orphaned session

# Content (Phase 1 - explicit)
hif cat <path>                    # Print file contents
hif write <path>                  # Write stdin to file
hif edit <path>                   # Edit file in $EDITOR
hif ls [path]                     # List directory

# Content (Phase 2 - via mount)
hif mount [path]                  # Mount virtual filesystem
hif unmount                       # Unmount

# Recording
hif decide "reasoning"            # Record a decision
hif converse "message"            # Add to conversation

# History
hif log                           # Show landed sessions
hif log --path <path>             # Sessions touching path
hif log --author <id>             # Sessions by author
hif diff <ref1> <ref2>            # Diff between states
hif blame <path>                  # Session that changed each line

# Navigation
hif goto @latest                  # Latest state
hif goto @position:N              # Specific position
hif goto @session:<id>            # Session's state

# Watching
hif watch                         # Stream repo events
hif watch --session <id>          # Watch specific session
```

---

## Concurrency at Scale

### Target Numbers

| Metric | Target |
|--------|--------|
| Files per repo | 100M+ |
| Landings per day | 100,000+ |
| Concurrent sessions | 10,000+ |
| Concurrent agents | 1,000+ |
| Queries per second | 100,000+ |

### How We Handle It

**1. Sharded Metadata**
```
repo_id → consistent hash → shard 0-255
Each shard is a CockroachDB range
Horizontal scaling by adding nodes
```

**2. Partitioned Landing**
```
Sessions touching disjoint paths land in parallel:
  src/auth/*     → partition 0
  src/payments/* → partition 1
Only cross-partition sessions serialize
```

**3. Bloom Filter Fast Path**
```
Conflict check:
  1. AND session bloom filters
  2. If zero bits: no conflict (guaranteed)
  3. If non-zero: check path_index (rare)

99% of landings take fast path
```

**4. Tiered Caching**
```
Tier 0: Client memory    (KB)   - hot files
Tier 1: Client disk      (GB)   - working set
Tier 2: CDN edge         (TB)   - popular blobs
Tier 3: Object store     (PB)   - everything
```

**5. Segmented Changelog**
```
Ancestry query in O(log n):
  - Sessions grouped into segments of 10,000
  - Precomputed ancestry bitmaps per segment
  - Cross-segment: O(log n) lookups
```

---

## Failure Handling

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Agent crash | Lease expires (no heartbeat) | Session orphaned, can be claimed |
| Forge unavailable | Connection timeout | Queue operations locally, sync on reconnect |
| Landing conflict | Bloom/path check | Mark CONFLICTED, agent resolves |
| Corrupt blob | Hash mismatch | Re-fetch from forge |
| Corrupt index | Checksum fail | Rebuild from source data |

---

## Codebase Structure

```
hif/
├── src/
│   ├── core/                    # libhif-core
│   │   ├── hash.zig            # Blake3 hashing, chunking
│   │   ├── bloom.zig           # Bloom filters
│   │   ├── tree.zig            # Prolly trees
│   │   ├── changelog.zig       # Segmented changelog
│   │   ├── hlc.zig             # Hybrid logical clock
│   │   └── c_api.zig           # C ABI exports
│   │
│   ├── client/                  # hif CLI
│   │   ├── main.zig            # Entry point
│   │   ├── commands/           # CLI commands
│   │   │   ├── session.zig
│   │   │   ├── content.zig
│   │   │   └── ...
│   │   ├── grpc.zig            # Forge client
│   │   ├── cache.zig           # Local cache
│   │   └── config.zig          # Configuration
│   │
│   ├── fs/                      # hif-fs (Phase 2)
│   │   ├── nfs.zig             # NFS server
│   │   ├── overlay.zig         # Session overlay
│   │   └── mount.zig           # Mount management
│   │
│   └── root.zig                 # Library entry
│
├── include/
│   └── hif_core.h               # C header
│
├── build.zig
└── DESIGN.md
```

### Build Outputs

```bash
$ zig build

zig-out/
├── bin/
│   ├── hif                      # CLI binary
│   └── hif-fs                   # FS daemon (Phase 2)
├── lib/
│   ├── libhif_core.a           # Static library
│   └── libhif_core.so          # Shared library
└── include/
    └── hif_core.h              # C header
```

---

## Implementation Phases

### Phase 1: Foundation (Months 1-3)

**libhif-core:**
- [ ] Blake3 hashing
- [ ] Bloom filters
- [ ] Basic tree (insert, delete, hash)
- [ ] HLC timestamps
- [ ] C API + header generation

**hif CLI:**
- [ ] Auth (token-based initially)
- [ ] session start/land/abandon
- [ ] decide, converse
- [ ] cat, write, edit, ls
- [ ] gRPC client (basic)

**Forge (separate repo):**
- [ ] Database schema
- [ ] gRPC server skeleton
- [ ] Basic session CRUD
- [ ] S3 blob storage

### Phase 2: Usability (Months 4-6)

**libhif-core:**
- [ ] Full prolly tree with efficient diff
- [ ] Segmented changelog
- [ ] Tree serialization

**hif CLI:**
- [ ] log, diff, blame
- [ ] goto navigation
- [ ] watch streaming

**hif-fs:**
- [ ] NFS server (read path)
- [ ] Local cache with LRU
- [ ] Session overlay (write path)
- [ ] Mount/unmount

### Phase 3: Scale (Months 7-9)

**libhif-core:**
- [ ] Delta compression
- [ ] Pack file format

**Forge:**
- [ ] Raft landing queue
- [ ] Sharded metadata
- [ ] CDN integration
- [ ] Webhooks

**Client:**
- [ ] Parallel blob fetching
- [ ] Prefetching
- [ ] Offline queue

### Phase 4: Production (Months 10-12)

- [ ] Multi-region forge
- [ ] Disaster recovery
- [ ] Monitoring + alerting
- [ ] Rate limiting
- [ ] Abuse prevention
- [ ] Git import tool

---

## Open Questions

### Offline Mode

Should small repos work without a forge?
- Useful for: personal projects, air-gapped environments
- Cost: two code paths to maintain

### Git Interop

What level of Git compatibility?
- Import: definitely (one-time migration)
- Export: maybe (escape hatch)
- Bidirectional sync: probably not worth complexity

### Session Hierarchy

Can sessions have sub-sessions?
```
Session: "Refactor auth"
├── Sub-session: "Extract JWT"
├── Sub-session: "Add refresh tokens"
└── Sub-session: "Update tests"
```

### IDE Integration

How should IDEs integrate?
- LSP-style daemon?
- Direct gRPC to forge?
- Via virtual filesystem only?

---

*This design targets Google/Meta scale while prioritizing agent-first workflows.*
