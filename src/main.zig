const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

/// Handle is like a uniq Id, which is used to retrieve a specific datum
/// stored in Entities data structure.
pub fn Handle(comptime T: anytype) type {
    return struct {
        index: usize,
        version: i32,

        const Self = @This();

        fn new(index: usize, version: i32) Self {
            return .{ .index = index, .version = version };
        }

        pub fn is_eq(lhs: Self, rhs: Self) bool {
            return lhs.version == rhs.version and lhs.index == rhs.index;
        }
    };
}

pub fn Entities(comptime T: anytype) type {
    return struct {
        data: ArrayList(T),
        handles: ArrayList(Handle(T)),
        free: ArrayList(usize),
        last_version: i32 = 0,

        _arena: *ArenaAllocator,

        const Self = @This();

        pub fn init(allocator: *Allocator) Self {
            var entities: Self = undefined;
            entities.last_version = 0;

            entities._arena = allocator.create(ArenaAllocator) catch |e| {
                panic("Crash :: {}.\n", .{e});
            };

            entities._arena.* = ArenaAllocator.init(allocator);

            entities.data = ArrayList(T).init(&entities._arena.allocator);
            entities.handles = ArrayList(Handle(T)).init(&entities._arena.allocator);
            entities.free = ArrayList(usize).init(&entities._arena.allocator);

            return entities;
        }

        pub fn append(self: *Self, item: T) !Handle(T) {
            var handle: Handle(T) = undefined;

            self.last_version += 1;

            const index = self.data.items.len;
            const version = self.last_version;

            if (self.free.items.len > 0) {
                const old_handle = &self.handles.items[self.free.pop()];
                old_handle.version = self.last_version;
                handle = old_handle.*;
                // Replace old data chunck by the new one.
                self.data.items[handle.index] = item;
            } else {
                handle = Handle(T).new(index, version);
                try self.handles.append(handle);
                // Append new data chunck.
                try self.data.append(item);
            }

            return handle;
        }

        pub fn get(self: *const Self, handle: Handle(T)) *T {
            if (!self.is_valid(handle)) {
                panic("Given handle not valid: '{}'\n", .{handle});
            }

            return &self.data.items[handle.index];
        }

        pub fn get_index(self: *const Self, handle: Handle(T)) ?usize {
            var index: ?usize = null;

            for (self.handles.items) |item, idx| {
                if (Handle(T).is_eq(item, handle)) {
                    index = idx;
                }
            }

            return index;
        }

        pub fn iterate(self: *Self) EntitiesIterator {
            return .{ .entities = self, .index = 0 };
        }

        pub fn remove(self: *Self, handle: Handle(T)) void {
            if (self.get_index(handle)) |idx| {
                self.last_version += 1;
                self.handles.items[idx].version = self.last_version;
                self.free.append(idx) catch |e| {
                    panic("Crash while removing entity: '{}'\n", .{e});
                };
            }
        }

        pub fn is_valid(self: *const Self, handle: Handle(T)) bool {
            var is_handle_valid = false;

            for (self.handles.items) |item| {
                if (item.is_eq(handle)) {
                    is_handle_valid = true;
                }
            }

            return is_handle_valid;
        }

        pub fn clear(self: *Self) void {
            for (self.handles.items) |handle, idx| {
                var already_freed = false;
                for (self.free.items) |free_idx| {
                    if (free_idx == idx) already_freed = true;
                }

                if (!already_freed) self.remove(handle);
            }
        }

        pub fn deinit(self: *Self) void {
            const allocator = self._arena.child_allocator;

            self._arena.deinit();
            allocator.destroy(self._arena);
        }

        pub const EntitiesIterator = struct {
            entities: *Self,
            index: usize,

            pub fn next(it: *EntitiesIterator) ?*T {
                const handles = it.entities.handles;

                while (it.index < handles.items.len) : (it.index += 1) {
                    var is_freed = false;

                    for (it.entities.free.items) |idx| {
                        if (it.index == idx) {
                            is_freed = true;
                            break;
                        }
                    }

                    if (!is_freed) {
                        const handle = handles.items[it.index];
                        it.index += 1;
                        return it.entities.get(handle);
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

    testing.expectEqual(entities.is_valid(Handle(i32).new(0, 1)), false);
    testing.expectEqual(entities.handles.items.len, 0);
    testing.expectEqual(entities.data.items.len, 0);
    testing.expectEqual(entities.free.items.len, 0);
    testing.expectEqual(entities.last_version, 0);
}

test "entities.append" {
    var entities = Entities(i32).init(testing.allocator);
    defer entities.deinit();

    const handle_1 = try entities.append(11);
    const handle_2 = try entities.append(22);
    const handle_3 = try entities.append(33);

    testing.expectEqual(Handle(i32).new(0, 1).is_eq(handle_1), true);
    testing.expectEqual(Handle(i32).new(1, 2).is_eq(handle_2), true);
    testing.expectEqual(Handle(i32).new(2, 3).is_eq(handle_3), true);
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
    testing.expectEqual(entities.get_index(handle_1), 0);
    testing.expectEqual(entities.get_index(handle_2), 1);
    testing.expectEqual(entities.get_index(handle_3), 2);
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
    testing.expectEqual(handle_2.is_eq(handle_4), false);
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

    const handle_1 = try entities.append(11.0);
    const handle_2 = try entities.append(5.0);
    const handle_3 = try entities.append(33.0);

    entities.remove(handle_2);

    var it = entities.iterate();
    var count: f32 = 0;
    while (it.next()) |value| : (count += value.*) {
        const expectedValue: f32 = if (count == 0) 11.0 else 33.0;
        testing.expectEqual(value.*, expectedValue);
    }

    testing.expectEqual(count, 44.0);
}
