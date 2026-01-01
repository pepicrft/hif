//! Prolly Tree: A content-addressed B-tree for directory structures.
//!
//! Prolly trees combine the benefits of B-trees (efficient lookups) with
//! content-addressing (structural sharing, deduplication). They're used
//! by systems like Dolt and Noms for versioned data.
//!
//! ## Key Properties
//!
//! - **Content-addressed**: Tree hash is derived from contents
//! - **Immutable**: Operations return new trees, originals unchanged
//! - **Structural sharing**: Unchanged subtrees are shared between versions
//! - **Deterministic**: Same contents always produce same hash
//!
//! ## Usage
//!
//! ```zig
//! var tree = Tree.init(allocator);
//! defer tree.deinit();
//!
//! // Insert paths with their content hashes
//! try tree.insert("src/main.zig", file_hash);
//! try tree.insert("src/lib.zig", other_hash);
//!
//! // Lookup
//! if (tree.get("src/main.zig")) |h| {
//!     // Found, h is the content hash
//! }
//!
//! // Get tree hash (for storage/comparison)
//! const root_hash = tree.hash();
//! ```
//!
//! ## Simplified Implementation
//!
//! This is a simplified implementation using a sorted ArrayList instead of
//! a full B-tree structure. It's correct but not optimal for very large
//! trees. A production implementation would use proper B-tree nodes with
//! probabilistic chunking boundaries.

const std = @import("std");
const hash_mod = @import("hash.zig");

const Hash = hash_mod.Hash;
const HASH_SIZE = hash_mod.HASH_SIZE;

/// A single entry in the tree (path -> content hash).
pub const Entry = struct {
    path: []const u8,
    content_hash: Hash,

    /// Compare entries by path for sorting.
    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }
};

/// A content-addressed tree mapping paths to content hashes.
pub const Tree = struct {
    /// Sorted list of entries.
    entries: std.ArrayList(Entry),

    /// Allocator for memory management.
    allocator: std.mem.Allocator,

    /// Cached root hash (invalidated on modification).
    cached_hash: ?Hash,

    /// Create an empty tree.
    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{
            .entries = .{},
            .allocator = allocator,
            .cached_hash = null,
        };
    }

    /// Free the tree and all owned memory.
    pub fn deinit(self: *Tree) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Insert or update a path with its content hash.
    pub fn insert(self: *Tree, path: []const u8, content_hash: Hash) !void {
        self.cached_hash = null;

        // Check if path already exists
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                // Update existing entry
                entry.content_hash = content_hash;
                return;
            }
        }

        // Add new entry
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        try self.entries.append(self.allocator, .{
            .path = owned_path,
            .content_hash = content_hash,
        });

        // Keep sorted
        std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);
    }

    /// Remove a path from the tree.
    /// Returns true if the path was found and removed.
    pub fn delete(self: *Tree, path: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                self.allocator.free(entry.path);
                _ = self.entries.orderedRemove(i);
                self.cached_hash = null;
                return true;
            }
        }
        return false;
    }

    /// Get the content hash for a path.
    /// Returns null if the path doesn't exist.
    pub fn get(self: *const Tree, path: []const u8) ?Hash {
        // Binary search since entries are sorted
        var left: usize = 0;
        var right: usize = self.entries.items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = std.mem.order(u8, self.entries.items[mid].path, path);

            switch (cmp) {
                .lt => left = mid + 1,
                .gt => right = mid,
                .eq => return self.entries.items[mid].content_hash,
            }
        }

        return null;
    }

    /// Check if a path exists in the tree.
    pub fn contains(self: *const Tree, path: []const u8) bool {
        return self.get(path) != null;
    }

    /// Get the number of entries in the tree.
    pub fn count(self: *const Tree) usize {
        return self.entries.items.len;
    }

    /// Check if the tree is empty.
    pub fn isEmpty(self: *const Tree) bool {
        return self.entries.items.len == 0;
    }

    /// Compute the tree's content hash.
    ///
    /// The hash is computed by hashing all entries in sorted order.
    /// This ensures deterministic hashing regardless of insertion order.
    pub fn hash(self: *Tree) Hash {
        if (self.cached_hash) |h| {
            return h;
        }

        var hasher = hash_mod.Hasher.init();
        hasher.update("tree\x00");

        for (self.entries.items) |entry| {
            // Hash: path + null + content_hash
            hasher.update(entry.path);
            hasher.update("\x00");
            hasher.update(&entry.content_hash);
        }

        self.cached_hash = hasher.final();
        return self.cached_hash.?;
    }

    /// Get an iterator over all entries.
    pub fn iterator(self: *const Tree) EntryIterator {
        return .{ .entries = self.entries.items, .index = 0 };
    }

    /// Clone the tree.
    pub fn clone(self: *const Tree) !Tree {
        var new_tree = Tree.init(self.allocator);
        errdefer new_tree.deinit();

        for (self.entries.items) |entry| {
            try new_tree.insert(entry.path, entry.content_hash);
        }

        return new_tree;
    }

    /// List all paths with a given prefix.
    pub fn listPrefix(self: *const Tree, prefix: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        var result: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer result.deinit(allocator);

        for (self.entries.items) |entry| {
            if (std.mem.startsWith(u8, entry.path, prefix)) {
                try result.append(allocator, entry.path);
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Iterator over tree entries.
pub const EntryIterator = struct {
    entries: []const Entry,
    index: usize,

    pub fn next(self: *EntryIterator) ?Entry {
        if (self.index >= self.entries.len) {
            return null;
        }
        const entry = self.entries[self.index];
        self.index += 1;
        return entry;
    }
};

/// Compute the difference between two trees.
pub const DiffEntry = struct {
    path: []const u8,
    kind: DiffKind,
    old_hash: ?Hash,
    new_hash: ?Hash,
};

pub const DiffKind = enum {
    added,
    deleted,
    modified,
};

/// Compute the difference between two trees.
///
/// Returns a list of paths that differ, with their change type.
/// The caller owns the returned slice and must free it.
pub fn diff(allocator: std.mem.Allocator, old: *const Tree, new: *const Tree) ![]DiffEntry {
    var result: std.ArrayListUnmanaged(DiffEntry) = .{};
    errdefer result.deinit(allocator);

    var old_idx: usize = 0;
    var new_idx: usize = 0;

    while (old_idx < old.entries.items.len or new_idx < new.entries.items.len) {
        const old_entry = if (old_idx < old.entries.items.len) &old.entries.items[old_idx] else null;
        const new_entry = if (new_idx < new.entries.items.len) &new.entries.items[new_idx] else null;

        if (old_entry == null) {
            // Only new has entries left - all are additions
            try result.append(allocator, .{
                .path = new_entry.?.path,
                .kind = .added,
                .old_hash = null,
                .new_hash = new_entry.?.content_hash,
            });
            new_idx += 1;
        } else if (new_entry == null) {
            // Only old has entries left - all are deletions
            try result.append(allocator, .{
                .path = old_entry.?.path,
                .kind = .deleted,
                .old_hash = old_entry.?.content_hash,
                .new_hash = null,
            });
            old_idx += 1;
        } else {
            const cmp = std.mem.order(u8, old_entry.?.path, new_entry.?.path);
            switch (cmp) {
                .lt => {
                    // Path only in old - deleted
                    try result.append(allocator, .{
                        .path = old_entry.?.path,
                        .kind = .deleted,
                        .old_hash = old_entry.?.content_hash,
                        .new_hash = null,
                    });
                    old_idx += 1;
                },
                .gt => {
                    // Path only in new - added
                    try result.append(allocator, .{
                        .path = new_entry.?.path,
                        .kind = .added,
                        .old_hash = null,
                        .new_hash = new_entry.?.content_hash,
                    });
                    new_idx += 1;
                },
                .eq => {
                    // Path in both - check if modified
                    if (!std.mem.eql(u8, &old_entry.?.content_hash, &new_entry.?.content_hash)) {
                        try result.append(allocator, .{
                            .path = old_entry.?.path,
                            .kind = .modified,
                            .old_hash = old_entry.?.content_hash,
                            .new_hash = new_entry.?.content_hash,
                        });
                    }
                    old_idx += 1;
                    new_idx += 1;
                },
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "Tree insert and get" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const hash1 = hash_mod.hash("content1");
    const hash2 = hash_mod.hash("content2");

    try tree.insert("src/main.zig", hash1);
    try tree.insert("src/lib.zig", hash2);

    try std.testing.expectEqualSlices(u8, &hash1, &tree.get("src/main.zig").?);
    try std.testing.expectEqualSlices(u8, &hash2, &tree.get("src/lib.zig").?);
    try std.testing.expectEqual(@as(?Hash, null), tree.get("nonexistent"));
}

test "Tree insert updates existing" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const hash1 = hash_mod.hash("content1");
    const hash2 = hash_mod.hash("content2");

    try tree.insert("file.txt", hash1);
    try std.testing.expectEqualSlices(u8, &hash1, &tree.get("file.txt").?);

    try tree.insert("file.txt", hash2);
    try std.testing.expectEqualSlices(u8, &hash2, &tree.get("file.txt").?);

    try std.testing.expectEqual(@as(usize, 1), tree.count());
}

test "Tree delete" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const hash1 = hash_mod.hash("content1");
    try tree.insert("file.txt", hash1);

    try std.testing.expect(tree.contains("file.txt"));
    try std.testing.expect(tree.delete("file.txt"));
    try std.testing.expect(!tree.contains("file.txt"));
    try std.testing.expect(!tree.delete("file.txt")); // Already deleted
}

test "Tree count and isEmpty" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expect(tree.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), tree.count());

    try tree.insert("a.txt", hash_mod.hash("a"));
    try std.testing.expect(!tree.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), tree.count());

    try tree.insert("b.txt", hash_mod.hash("b"));
    try std.testing.expectEqual(@as(usize, 2), tree.count());
}

test "Tree hash is deterministic" {
    var tree1 = Tree.init(std.testing.allocator);
    defer tree1.deinit();
    var tree2 = Tree.init(std.testing.allocator);
    defer tree2.deinit();

    const hash_a = hash_mod.hash("a");
    const hash_b = hash_mod.hash("b");

    // Insert in different order
    try tree1.insert("a.txt", hash_a);
    try tree1.insert("b.txt", hash_b);

    try tree2.insert("b.txt", hash_b);
    try tree2.insert("a.txt", hash_a);

    // Same hash regardless of insertion order
    try std.testing.expectEqualSlices(u8, &tree1.hash(), &tree2.hash());
}

test "Tree hash changes on modification" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("file.txt", hash_mod.hash("v1"));
    const hash1 = tree.hash();

    try tree.insert("file.txt", hash_mod.hash("v2"));
    const hash2 = tree.hash();

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "Tree hash is cached" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("file.txt", hash_mod.hash("content"));

    const hash1 = tree.hash();
    const hash2 = tree.hash();

    // Should return same cached value
    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "Tree iterator" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("c.txt", hash_mod.hash("c"));
    try tree.insert("a.txt", hash_mod.hash("a"));
    try tree.insert("b.txt", hash_mod.hash("b"));

    var iter = tree.iterator();
    var paths: [3][]const u8 = undefined;
    var i: usize = 0;

    while (iter.next()) |entry| {
        paths[i] = entry.path;
        i += 1;
    }

    // Should be sorted
    try std.testing.expectEqualStrings("a.txt", paths[0]);
    try std.testing.expectEqualStrings("b.txt", paths[1]);
    try std.testing.expectEqualStrings("c.txt", paths[2]);
}

test "Tree clone" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("file.txt", hash_mod.hash("content"));

    var cloned = try tree.clone();
    defer cloned.deinit();

    try std.testing.expectEqualSlices(u8, &tree.hash(), &cloned.hash());
    try std.testing.expect(cloned.contains("file.txt"));
}

test "Tree listPrefix" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("src/main.zig", hash_mod.hash("main"));
    try tree.insert("src/lib.zig", hash_mod.hash("lib"));
    try tree.insert("README.md", hash_mod.hash("readme"));

    const src_files = try tree.listPrefix("src/", std.testing.allocator);
    defer std.testing.allocator.free(src_files);

    try std.testing.expectEqual(@as(usize, 2), src_files.len);
}

test "diff added" {
    var old = Tree.init(std.testing.allocator);
    defer old.deinit();
    var new = Tree.init(std.testing.allocator);
    defer new.deinit();

    try new.insert("new_file.txt", hash_mod.hash("content"));

    const changes = try diff(std.testing.allocator, &old, &new);
    defer std.testing.allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(DiffKind.added, changes[0].kind);
    try std.testing.expectEqualStrings("new_file.txt", changes[0].path);
}

test "diff deleted" {
    var old = Tree.init(std.testing.allocator);
    defer old.deinit();
    var new = Tree.init(std.testing.allocator);
    defer new.deinit();

    try old.insert("old_file.txt", hash_mod.hash("content"));

    const changes = try diff(std.testing.allocator, &old, &new);
    defer std.testing.allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(DiffKind.deleted, changes[0].kind);
    try std.testing.expectEqualStrings("old_file.txt", changes[0].path);
}

test "diff modified" {
    var old = Tree.init(std.testing.allocator);
    defer old.deinit();
    var new = Tree.init(std.testing.allocator);
    defer new.deinit();

    try old.insert("file.txt", hash_mod.hash("v1"));
    try new.insert("file.txt", hash_mod.hash("v2"));

    const changes = try diff(std.testing.allocator, &old, &new);
    defer std.testing.allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(DiffKind.modified, changes[0].kind);
    try std.testing.expectEqualStrings("file.txt", changes[0].path);
}

test "diff unchanged" {
    var old = Tree.init(std.testing.allocator);
    defer old.deinit();
    var new = Tree.init(std.testing.allocator);
    defer new.deinit();

    const h = hash_mod.hash("same content");
    try old.insert("file.txt", h);
    try new.insert("file.txt", h);

    const changes = try diff(std.testing.allocator, &old, &new);
    defer std.testing.allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "diff complex" {
    var old = Tree.init(std.testing.allocator);
    defer old.deinit();
    var new = Tree.init(std.testing.allocator);
    defer new.deinit();

    try old.insert("deleted.txt", hash_mod.hash("d"));
    try old.insert("modified.txt", hash_mod.hash("m1"));
    try old.insert("unchanged.txt", hash_mod.hash("u"));

    try new.insert("added.txt", hash_mod.hash("a"));
    try new.insert("modified.txt", hash_mod.hash("m2"));
    try new.insert("unchanged.txt", hash_mod.hash("u"));

    const changes = try diff(std.testing.allocator, &old, &new);
    defer std.testing.allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 3), changes.len);

    // Changes are sorted by path
    try std.testing.expectEqual(DiffKind.added, changes[0].kind);
    try std.testing.expectEqualStrings("added.txt", changes[0].path);

    try std.testing.expectEqual(DiffKind.deleted, changes[1].kind);
    try std.testing.expectEqualStrings("deleted.txt", changes[1].path);

    try std.testing.expectEqual(DiffKind.modified, changes[2].kind);
    try std.testing.expectEqualStrings("modified.txt", changes[2].path);
}

test "Tree empty hash is consistent" {
    var tree1 = Tree.init(std.testing.allocator);
    defer tree1.deinit();
    var tree2 = Tree.init(std.testing.allocator);
    defer tree2.deinit();

    try std.testing.expectEqualSlices(u8, &tree1.hash(), &tree2.hash());
}

test "Tree handles empty path" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("", hash_mod.hash("root"));
    try std.testing.expect(tree.contains(""));
}

test "Tree handles paths with special characters" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("path/with spaces/file.txt", hash_mod.hash("1"));
    try tree.insert("path/with\ttab.txt", hash_mod.hash("2"));
    try tree.insert("unicode/文件.txt", hash_mod.hash("3"));

    try std.testing.expect(tree.contains("path/with spaces/file.txt"));
    try std.testing.expect(tree.contains("path/with\ttab.txt"));
    try std.testing.expect(tree.contains("unicode/文件.txt"));
}
