//! macOS entry point: owns the main loop and the terminal; filesystem work goes through fsops.
const std = @import("std");
const core = @import("core");
const tui_mod = @import("tui");
const scan = @import("scan_pool");
const fsops = @import("fsops");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena_init = init.arena.allocator();
    const env = try fsops.Env.init(arena_init, init.environ_map);
    const args = try fsops.parseArgs(try init.minimal.args.toSlice(arena_init));
    const root_path = try std.Io.Dir.cwd().realPathFileAlloc(io, args.path orelse env.home, arena_init);

    var app = try core.App.init(gpa, root_path);
    defer app.deinit();
    app.dry_run = args.dry_run;
    try fsops.loadKeymap(gpa, io, env, &app);

    var tui: tui_mod.Tui = undefined;
    try tui.init(gpa, io, init.environ_map);
    defer tui.deinit();

    var scanner = scan.Scanner.init(gpa, io, &app, .{ .ctx = &tui, .func = tui_mod.Tui.wake });
    defer scanner.deinit();
    var listing: scan.Listing = .{};
    defer listing.deinit(gpa);

    scanner.lock();
    try fsops.listOuter(gpa, &app, &listing);
    try fsops.readDisk(gpa, &app);
    try scanner.registerLocked(app.root);
    try scanner.pushLocked(&.{app.root});
    scanner.unlock();
    try scanner.start(args.jobs);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        scanner.lock();
        const v = app.view(arena.allocator());
        scanner.unlock();
        try tui.draw(arena.allocator(), try v);

        // Blink ticks only recolor the cells drawn above; any other event rebuilds the view.
        const pressed: ?core.Key = while (true) {
            switch (try tui.next()) {
                .tick => try tui.blink(),
                .key_press => |k| break tui_mod.coreKey(k),
                else => break null,
            }
        };
        const key = pressed orelse continue;
        scanner.lock();
        defer scanner.unlock();
        const cmd = try app.handleKey(key);
        if (try fsops.execute(gpa, io, env, &app, &scanner, &listing, tui.pageRows(), cmd)) break;
    }
}
