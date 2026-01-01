# hif - Design

A version control system for an agent-first world, designed for scale.

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
- **S3-first storage** - object storage scales infinitely, no database to manage
- **Lazy everything** - fetch only what you need, when you need it
- **Operations scale with your work**, not project size

---

## Architecture Overview

hif has three components that work together:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                               CLIENT (Zig)                                   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      libhif-core (native Zig)                       │   │
│  │   Trees · Bloom Filters · Segmented Changelog · HLC · Hash          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                   │                                         │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                  │
│  │   hif CLI     │  │   hif-fs      │  │  Local Cache  │                  │
│  │               │  │  (Phase 2)    │  │               │                  │
│  │ session start │  │  NFS daemon   │  │  Blob LRU     │                  │
│  │ session land  │  │  Mount point  │  │  Tree cache   │                  │
│  └───────────────┘  └───────────────┘  └───────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ HTTPS
                                    │
┌─────────────────────────────────────────────────────────────────────────────┐
│                         FORGE (stateless compute)                            │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      API Servers (Fly.io / Lambda / etc.)           │   │
│  │                                                                     │   │
│  │   Auth · Session CRUD · Blob upload/download · Tree operations     │   │
│  │   Scales horizontally, stateless                                   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                   │                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      Landing Coordinator                            │   │
│  │                                                                     │   │
│  │   Serializes landings · Conflict detection · Writes to S3          │   │
│  │   Single process, ~200 lines, stateless restart from S3            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
          ┌─────────────────────────┴─────────────────────────┐
          │                                                   │
          ▼                                                   ▼
┌───────────────────────┐                         ┌───────────────────────┐
│   SQLite + Litestream │                         │          S3           │
│                       │                         │                       │
│   Auth database:      │                         │   All hif data:       │
│   - Users             │                         │   - Sessions          │
│   - Tokens            │                         │   - Trees             │
│   - Permissions       │                         │   - Blobs             │
│                       │                         │   - Landed index      │
│   Replicated to S3    │                         │                       │
│   ~KB per user        │                         │   Infinitely scalable │
└───────────────────────┘                         └───────────────────────┘
```

### Component Responsibilities

| Component | Language | Runs | Responsibility |
|-----------|----------|------|----------------|
| **libhif-core** | Zig (C ABI) | Anywhere | Algorithms: trees, bloom, changelog, hashing |
| **Forge** | Any (Elixir, Go, etc.) | Cloud | Stateless API, landing coordination |
| **hif CLI** | Zig | Local | User/agent interface |
| **hif-fs** | Zig | Local | Virtual filesystem (Phase 2) |
| **S3** | - | Cloud | All hif data (sessions, trees, blobs) |
| **SQLite** | - | Forge | Auth only (users, tokens, permissions) |

### Why This Split?

**libhif-core exists because:**
- Algorithms are complex (prolly trees, segmented changelog)
- Getting them right is hard (edge cases, correctness)
- Performance matters (hot path operations)
- Write once, use in any language

**Forge is stateless because:**
- All state lives in S3 (infinitely scalable)
- Horizontal scaling is trivial (just add nodes)
- No database clustering, no Raft, no complexity
- Can run on Lambda/Fly.io (scale to zero)

**S3 for hif data because:**
- Blobs are immutable (content-addressed)
- Sessions are append-mostly
- Infinitely scalable, $0.023/GB/month
- Strong consistency (since 2020)
- 11 nines durability

**SQLite + Litestream for auth because:**
- Auth data is small (~KB per user)
- Simple relational queries (users, permissions)
- Litestream replicates to S3 continuously
- No vendor lock-in, fully open source
- Can migrate to Postgres/Turso if needed later

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

The forge is stateless compute. All state lives in S3.

### S3 Storage Structure

All hif data (sessions, trees, blobs) is stored in S3:

```
s3://hif-{org}/
└── projects/
    └── {project_id}/
        │
        ├── meta.json                    # Project metadata
        │   {
        │     "id": "proj_abc123",
        │     "name": "myapp",
        │     "created_at": "2024-01-01T00:00:00Z"
        │   }
        │
        ├── head.json                    # Current head position + tree hash
        │   {
        │     "position": 847293,
        │     "tree_hash": "abc123...",
        │     "updated_at": "2024-01-15T10:30:00Z"
        │   }
        │
        ├── sessions/
        │   └── {session_id}.json        # Complete session state
        │       {
        │         "id": "ses_7f3a2b1c",
        │         "goal": "Add authentication",
        │         "owner_id": "user_xyz",
        │         "state": "open",
        │         "base_position": 847290,
        │         "operations": [
        │           {"seq": 1, "op": "write", "path": "src/auth.ts", "hash": "..."},
        │           {"seq": 2, "op": "write", "path": "src/login.ts", "hash": "..."}
        │         ],
        │         "decisions": ["Using JWT for auth"],
        │         "conversation": [
        │           {"role": "human", "content": "Add login"},
        │           {"role": "agent", "content": "I'll use JWT"}
        │         ],
        │         "bloom_filter": "base64...",
        │         "landed_position": null,
        │         "hlc_created": "...",
        │         "hlc_updated": "..."
        │       }
        │
        ├── landed/
        │   └── {position}.json          # Landed session summary (sparse)
        │       {
        │         "session_id": "ses_7f3a2b1c",
        │         "tree_hash": "def456...",
        │         "paths": ["src/auth.ts", "src/login.ts"],
        │         "bloom_filter": "base64..."
        │       }
        │
        ├── trees/
        │   └── {hash}.json              # Serialized tree (content-addressed)
        │
        ├── blobs/
        │   └── {hash[0:2]}/
        │       └── {hash}               # Raw blob content (zstd compressed)
        │
        └── indexes/                     # Optional, for faster queries
            ├── sessions_by_owner.json   # owner_id → [session_ids]
            └── paths.json               # path → [positions] for blame
```

### Auth Database (SQLite)

Only auth-related data lives in SQLite (replicated to S3 via Litestream):

```sql
-- Users
CREATE TABLE users (
    id TEXT PRIMARY KEY,              -- "user_abc123"
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);

-- API tokens
CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    token_hash TEXT NOT NULL,
    name TEXT,
    expires_at TEXT,
    created_at TEXT NOT NULL
);

-- Project permissions
CREATE TABLE permissions (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id),
    role TEXT NOT NULL,               -- 'owner', 'write', 'read'
    created_at TEXT NOT NULL,

    UNIQUE (project_id, user_id)
);
```

This database stays tiny (KB per user) and is replicated to S3 every second.

### Landing Coordinator

The only piece that needs serialization is landing. A simple coordinator handles this:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Landing Coordinator                           │
│                                                                 │
│   In-memory:                                                    │
│     current_position: 847293                                    │
│     pending_lands: Queue<LandRequest>                           │
│                                                                 │
│   On startup:                                                   │
│     Read head.json from S3 → current_position                   │
│                                                                 │
│   On land request:                                              │
│     1. Load session from S3                                     │
│     2. Load landed/{base+1..current}.json for conflict check    │
│     3. Check bloom filter intersections                         │
│     4. If conflict: mark session CONFLICTED, return             │
│     5. Increment position                                       │
│     6. Write landed/{position}.json                             │
│     7. Write new tree to trees/{hash}.json                      │
│     8. Update head.json                                         │
│     9. Update session state to "landed"                         │
│                                                                 │
│   Stateless restart:                                            │
│     All state reconstructed from S3                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

For higher throughput, partition by path prefix:
```
src/auth/*     → coordinator A
src/payments/* → coordinator B

Non-overlapping paths land in parallel.
```

### Blob Format

```
Small files (<4MB):
  [4 bytes: magic "HIFB"]
  [4 bytes: uncompressed size]
  [zstd compressed content]

Large files (>4MB) are chunked:
  [4 bytes: magic "HIFC"]
  [4 bytes: chunk count]
  [N x 32 bytes: chunk hashes]

  Each chunk stored separately as a blob.
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
hif project create <name>         # Create new project on forge
hif clone <project>               # Clone project locally

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
hif watch                         # Stream project events
hif watch --session <id>          # Watch specific session
```

---

## Concurrency at Scale

### Target Numbers

| Metric | Target |
|--------|--------|
| Files per project | 100M+ |
| Landings per day | 100,000+ |
| Concurrent sessions | 10,000+ |
| Concurrent agents | 1,000+ |
| Queries per second | 100,000+ |

### How We Handle It

**1. S3 Scales Infinitely**
```
All hif data lives in S3:
  - No database sharding needed
  - No connection pool limits
  - Automatic replication and durability
  - Pay only for what you use
```

**2. Stateless API Servers**
```
Forge API servers are stateless:
  - Horizontal scaling (just add nodes)
  - Scale to zero when idle
  - Run on Lambda/Fly.io/Cloud Run
  - No state to replicate or sync
```

**3. Partitioned Landing**
```
Sessions touching disjoint paths land in parallel:
  src/auth/*     → coordinator A
  src/payments/* → coordinator B

Only cross-partition sessions serialize.
Single coordinator handles 1000s of landings/day.
```

**4. Bloom Filter Fast Path**
```
Conflict check:
  1. Load bloom filters from landed/*.json
  2. AND with session bloom filter
  3. If zero bits: no conflict (guaranteed)
  4. If non-zero: check actual paths (rare)

99% of landings take fast path.
```

**5. Tiered Caching**
```
Tier 0: Client memory    (KB)   - hot files
Tier 1: Client disk      (GB)   - working set
Tier 2: CDN edge         (TB)   - popular blobs
Tier 3: S3               (PB)   - everything
```

**6. CDN for Reads**
```
Blobs are immutable (content-addressed):
  - CloudFront/Cloudflare in front of S3
  - Infinite cache TTL
  - Global edge distribution
  - Most reads never hit S3
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

### Phase 1: Foundation

**libhif-core:**
- [x] Blake3 hashing
- [x] Bloom filters
- [x] Basic tree (insert, delete, hash)
- [x] HLC timestamps
- [x] C API + header

**hif CLI:**
- [x] Project/clone/auth command structure
- [ ] Session start/land/abandon
- [ ] Local config (~/.hif/)
- [ ] HTTP client to forge

**Forge:**
- [ ] SQLite + Litestream setup
- [ ] Auth (users, tokens)
- [ ] S3 storage layer
- [ ] Session CRUD (read/write to S3)
- [ ] Basic API endpoints

### Phase 2: Landing

**Forge:**
- [ ] Landing coordinator
- [ ] Conflict detection (bloom filters)
- [ ] Tree building on land
- [ ] head.json updates

**hif CLI:**
- [ ] session land command
- [ ] Conflict resolution flow
- [ ] cat, write, edit, ls

### Phase 3: Usability

**libhif-core:**
- [ ] Tree serialization
- [ ] Segmented changelog

**hif CLI:**
- [ ] log, diff, blame
- [ ] goto navigation
- [ ] watch (polling initially)

**hif-fs:**
- [ ] NFS server (read path)
- [ ] Local cache with LRU
- [ ] Session overlay (write path)
- [ ] Mount/unmount

### Phase 4: Production

**Forge:**
- [ ] CDN integration
- [ ] Rate limiting
- [ ] Webhooks
- [ ] Partitioned landing (if needed)

**Operations:**
- [ ] Monitoring + alerting
- [ ] S3 replication (multi-region)
- [ ] Git import tool

---

## Open Questions

### Offline Mode

Should small projects work without a forge?
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
