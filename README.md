# ion-extras

I've been working on a game engine written in zig, called `ion`. It's a work-in-progress and not ready to open source yet.

This repo contains portions of the engine that don't rely on the engine itself and can be used as standalone libraries.

This code is a work-in-progress and is subject to change at any time.

## Libraries

- `relative`: Data structures that point to data that is relative to their own storage. Useful for creating memory-mappable variable length data structures.
- `serialize`: Mappable and non-mappable binary serialization with versioning support.
- `extra_data`: A similar concept to `relative`, but with all the trailing fields declared together, and a bit-packed lengths field.

More detailed documentation for each library is in the source files themselves.

The tests in each file provide usage examples.

## Getting started

Copy `ion-extras` into a subdirectory of your project, or add it as a submodule.

In build.zig.zon:

```
.dependencies = .{
    .extras = .{ .path = "deps/ion-extras" },
    ...
```

In build.zig:


```
    const ion_extras = b.dependency("extras", .{});
    exe.root_module.addImport("extras", ion_extras.module("root"));
```
