# Entities

Generic system of entities written in zig. Without ABA problems, using
generational index in order to access the associated data. The code is clear and simple to understand.

## Examples

```zig
usingnamespace @import("entities");

pub fn main () void {
  var entities = Entities(f32).init(default_allocator);

  const handle_1 = try entities.append(1.5);
  const handle_2 = try entities.append(2.5);
  const handle_3 = try entities.append(3.5);

  // Getting the inner data by using associated handle.
  print("{}\n", .{entities.get(handle_2)});

  // Removes data using bucket pooling.
  entities.remove(handle_1);

  // Iterator over all active handles.
  var it = entities.interate();
  while(it.next()) |datum| {
    print("datum: {}\n", .{datum.*});
  }

}
```
