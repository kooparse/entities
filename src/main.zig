const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const AutoHashMap = std.AutoHashMap;

/// Handle is like a uniq Id, which is used to retrieve a specific datum
/// stored in Entities data structure.
pub fn Handle(comptime T: anytype) type {
    return struct {
        id: i32,

        pub fn new(id: i32) @This() {
            return .{ .id = id };
        }
    };
}

/// Entities datastructure had to meet strict requirements:
///
/// 1) Refering stored data chuncks as simple integer because it's much
///    easy to serialized it.
///
/// 2) Shouldn't suffer from ABA problems.
///
/// 3) Being able to preallocate bunch of ids
///    (used when ids are stored on the system and refered to other ones).
///
pub fn Entities(comptime T: anytype) type {
    return struct {
        /// Data stored
        data: ArrayList(T),
        /// Handle composed by the generational id as `key` and
        /// data arraylist's index as `value`.
        handles: AutoHashMap(i32, usize),
        /// Array of all free handles, stored generational id
        /// in it.
        free: ArrayList(i32),
        /// keeping track of the last id incremented.
        last_id: i32 = 0,

        /// All postpone ids goes here.
        _prealloc: AutoHashMap(i32, void),

        /// Arena allocator, used to free all heap allocated data once.
        _arena: *ArenaAllocator,

        const Self = @This();

        pub fn init(allocator: *Allocator) Self {
            var entities: Self = undefined;
            entities.last_id = 0;

            entities._arena = allocator.create(ArenaAllocator) catch |e| {
                panic("Crash :: {}.\n", .{e});
            };

            entities._arena.* = ArenaAllocator.init(allocator);
            entities._prealloc = AutoHashMap(i32, void).init(&entities._arena.allocator);

            entities.data = ArrayList(T).init(&entities._arena.allocator);
            entities.handles = AutoHashMap(i32, usize).init(&entities._arena.allocator);
            entities.free = ArrayList(i32).init(&entities._arena.allocator);

            return entities;
        }

        pub fn append(self: *Self, item: T) !Handle(T) {
            if (self.free.items.len == 0) {
                self.increment_id(null);
            }

            return try self.add_chunk(item, self.last_id);
        }

        /// Store new item by using the given `id`.
        /// This method also checked with there are given `id` isn't
        /// alreayd used.
        pub fn append_hard(self: *Self, item: T, id: i32) !Handle(T) {
            if (self.handles.contains(id)) {
                panic("Given id '{}' is already in use.\n", .{id});
            }

            try self._prealloc.put(id, {});
            return try self.add_chunk(item, id);
        }

        fn add_chunk(self: *Self, item: T, id: i32) !Handle(T) {
            var handle: Handle(T) = .{ .id = id };

            const index = self.data.items.len;

            if (self.free.items.len > 0) {
                const data_index = self.handles.get(self.free.pop()).?;
                self.data.items[data_index] = item;
            } else {
                try self.handles.putNoClobber(id, index);
                try self.data.append(item);
            }

            return handle;
        }

        pub fn get(self: *const Self, handle: Handle(T)) *T {
            if (self.is_valid(handle)) {
                const data_index = self.handles.get(handle.id).?;
                return &self.data.items[data_index];
            } else {
                panic("Given handle not valid: '{}'\n", .{handle});
            }
        }

        fn increment_id(self: *Self, next: ?i32) void {
            const next_version = if (next) |v| v else self.last_id + 1;

            if (self._prealloc.contains(next_version)) {
                increment_id(self, next_version + 1);
            } else {
                self.last_id = next_version;
            }
        }

        pub fn iterate(self: *Self) EntitiesIterator {
            return .{ .entities = self, .index = 0 };
        }

        pub fn get_count(self: *Self) i32 {
            var count: i32 = 0;

            var it = self.iterate();
            while (it.next()) |_| count += 1;

            return count;
        }

        pub fn remove(self: *Self, handle: Handle(T)) void {
            if (self.is_valid(handle)) {
                increment_id(self, null);

                const old_entry = self.handles.getEntry(handle.id).?.*;
                self.handles.putNoClobber(self.last_id, old_entry.value) catch unreachable;
                self.handles.removeAssertDiscard(old_entry.key);

                self.free.append(self.last_id) catch |e| {
                    panic("Crash while removing entity: '{}'\n", .{e});
                };
            }
        }

        pub fn is_valid(self: *const Self, handle: Handle(T)) bool {
            var is_handle_valid = false;

            if (self.handles.contains(handle.id)) {
                is_handle_valid = true;

                for (self.free.items) |item| {
                    if (item == handle.id) is_handle_valid = false;
                }
            }

            return is_handle_valid;
        }

        pub fn clear(self: *Self) void {
            var it = self.handles.iterator();
            while (it.next()) |entry| {
                var already_freed = false;

                for (self.free.items) |free_idx| {
                    if (free_idx == entry.key) already_freed = true;
                }

                if (!already_freed) self.remove(.{ .id = entry.key });
            }
        }

        pub fn deinit(self: *Self) void {
            const allocator = self._arena.child_allocator;

            self._arena.deinit();
            allocator.destroy(self._arena);
        }

        pub const EntitiesIterator = struct {
            entities: *Self,
            index: u32,

            pub fn next(it: *EntitiesIterator) ?*T {
                const handles = it.entities.handles;

                var iter = it.entities.handles.iterator();
                iter.index = it.index;

                while (iter.next()) |entry| {
                    var is_freed = false;
                    it.index = iter.index;

                    for (it.entities.free.items) |idx| {
                        if (entry.key == idx) {
                            is_freed = true;
                            break;
                        }
                    }

                    if (!is_freed) {
                        return &it.entities.data.items[entry.value];
                    }
                }

                return null;
            }
        };
    };
}

test "entities.init" {
    var entities = Entities(i32).init(testing.allocator);
    defer entities.deinit();

    testing.expectEqual(entities.is_valid(Handle(i32).new(0)), false);
    testing.expectEqual(entities.handles.unmanaged.size, 0);
    testing.expectEqual(entities.data.items.len, 0);
    testing.expectEqual(entities.free.items.len, 0);
    testing.expectEqual(entities.last_id, 0);
}

test "entities.append" {
    var entities = Entities(i32).init(testing.allocator);
    defer entities.deinit();

    const handle_1 = try entities.append(11);
    const handle_2 = try entities.append(22);
    const handle_3 = try entities.append(33);

    testing.expectEqual(entities.handles.get(1).? == 0, true);
    testing.expectEqual(entities.handles.get(2).? == 1, true);
    testing.expectEqual(entities.handles.get(3).? == 2, true);
}

test "entities.get" {
    var entities = Entities(f32).init(testing.allocator);
    defer entities.deinit();

    const handle_1 = try entities.append(11.0);
    const handle_2 = try entities.append(22.0);
    const handle_3 = try entities.append(33.0);

    testing.expectEqual(entities.get(handle_1).*, 11.0);
    testing.expectEqual(entities.get(handle_2).*, 22.0);
    testing.expectEqual(entities.get(handle_3).*, 33.0);
}

test "entities.remove" {
    var entities = Entities(i32).init(testing.allocator);
    defer entities.deinit();

    const handle_1 = try entities.append(11);
    const handle_2 = try entities.append(22);
    const handle_3 = try entities.append(33);

    entities.remove(handle_2);
    testing.expectEqual(entities.free.items.len, 1);
    testing.expectEqual(entities.is_valid(handle_2), false);

    const handle_4 = try entities.append(44);
    testing.expectEqual(handle_2.id == handle_4.id, false);
    testing.expectEqual(entities.is_valid(handle_2), false);
    testing.expectEqual(entities.free.items.len, 0);
    testing.expectEqual(entities.get(handle_4).*, 44);
}

test "entities.clear" {
    var entities = Entities(i32).init(testing.allocator);
    defer entities.deinit();

    const handle_1 = try entities.append(11);
    const handle_2 = try entities.append(22);
    const handle_3 = try entities.append(33);

    testing.expectEqual(entities.is_valid(handle_1), true);
    testing.expectEqual(entities.is_valid(handle_2), true);
    testing.expectEqual(entities.is_valid(handle_3), true);

    entities.clear();

    testing.expectEqual(entities.is_valid(handle_1), false);
    testing.expectEqual(entities.is_valid(handle_2), false);
    testing.expectEqual(entities.is_valid(handle_3), false);
}

test "entities.interator" {
    var entities = Entities(f32).init(testing.allocator);
    defer entities.deinit();

    const handle_1 = try entities.append(10.0);
    const handle_2 = try entities.append(20.0);
    const handle_3 = try entities.append(30.0);

    entities.remove(handle_2);

    var it = entities.iterate();
    var count: f32 = 0;
    while (it.next()) |value| : (count += value.*) {
        const expectedValue: f32 = if (count == 0) 10.0 else 30.0;
        testing.expectEqual(value.*, expectedValue);
    }

    testing.expectEqual(count, 40);
}
