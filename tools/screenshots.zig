//! `zig build screenshots`: renders README screenshots. Mock scan results go through the real core
//! (`App`) and are drawn by the real `tui.paint()` into an in-memory screen, which is written out as SVG.
const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core");
const tui = @import("tui");
const Allocator = std.mem.Allocator;

const COLS = 110;
const ROWS = 26;
const G = 1 << 30;
const M = 1 << 20;
const K = 1 << 10;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_dir_path = if (args.len > 1) args[1] else "docs/img";
    try std.Io.Dir.cwd().createDirPath(io, out_dir_path);
    var out_dir = try std.Io.Dir.cwd().openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    const scenes = [_]struct { file: []const u8, title: []const u8, dry_run: bool, keys: []const u8 }{
        .{ .file = "browse.svg", .title = "space-hog ~", .dry_run = false, .keys = "l" },
        .{ .file = "dry-run.svg", .title = "space-hog -n ~", .dry_run = true, .keys = "ljXy" },
        .{ .file = "delete-prompt.svg", .title = "space-hog ~", .dry_run = false, .keys = "ljX" },
        .{ .file = "log.svg", .title = "space-hog -n ~", .dry_run = true, .keys = "ljxjXy!" },
    };
    for (scenes) |scene| {
        var app = try mockHome(gpa);
        defer app.deinit();
        app.dry_run = scene.dry_run;
        for (scene.keys) |k| _ = try app.handleKey(core.Key.char(k));

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var screen: vaxis.Screen = try .init(gpa, .{ .rows = ROWS, .cols = COLS, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = COLS, .height = ROWS, .screen = &screen };
        var frame: tui.Frame = .{};
        try tui.paint(arena.allocator(), win, try app.view(arena.allocator()), &frame);

        const svg = try toSvg(arena.allocator(), &screen, scene.title);
        try out_dir.writeFile(io, .{ .sub_path = scene.file, .data = svg });
    }
}

fn d(name: []const u8, size: u64) core.Entry {
    return .{ .name = name, .kind = .dir, .size = size };
}

fn f(name: []const u8, size: u64) core.Entry {
    return .{ .name = name, .kind = .file, .size = size };
}

/// Finds `name` under `parent` (the mock always adds it first).
fn child(app: *core.App, parent: core.NodeId, name: []const u8) core.NodeId {
    var it = app.tree.get(parent).first_child;
    while (it != .nil) : (it = app.tree.get(it).next_sibling) {
        if (std.mem.eql(u8, app.tree.name(it), name)) return it;
    }
    unreachable;
}

/// A believable home directory. Sizes are what the scan would report (bytes on disk).
fn mockHome(gpa: Allocator) !core.App {
    var app = try core.App.init(gpa, "/Users/you");
    errdefer app.deinit();
    const home = app.root;
    try app.setOuter(&.{ d("you", 0), d("Shared", 0), d("Guest", 0) });
    try app.setDisk("/dev/disk3s5", 460 * G, 79 * G);
    _ = try app.addDir(home, &.{
        d("Library", 38 * G),    d("Development", 4 * K), d("Downloads", 9 * G), d("Movies", 6 * G),
        d("Pictures", 3 * G),    d("Documents", 1 * G),   d(".cache", 2 * G),    d("Music", 400 * M),
        d(".config", 12 * M),    d("Desktop", 30 * M),    f(".zsh_history", 2 * M), f(".gitconfig", 4 * K),
    });
    const dev = child(&app, home, "Development");
    _ = try app.addDir(dev, &.{
        d("android-app", 4 * K),   d("game-engine", 9 * G),   d("website", 2 * G),     d("ml-experiments", 7 * G),
        d("dotfiles", 40 * M),     d("rust-playground", 1 * G), d("old-prototype", 600 * M), d("notes", 8 * M),
        d("scripts", 3 * M),       d("cli-tools", 300 * M),   d("archive-2023", 450 * M), d("talks", 120 * M),
        f("TODO.md", 4 * K),
    });
    const android = child(&app, dev, "android-app");
    _ = try app.addDir(android, &.{
        d("build", 14 * G), d(".gradle", 3 * G), d("app", 600 * M), d(".git", 210 * M), d("node_modules", 380 * M),
        f("gradlew", 8 * K), f("README.md", 4 * K),
    });
    const engine = child(&app, dev, "game-engine");
    _ = try app.addDir(engine, &.{ d("assets", 0), d("target", 0), d("src", 0) });
    const ml = child(&app, dev, "ml-experiments");
    _ = try app.addDir(ml, &.{ d("datasets", 0), d("checkpoints", 0) });
    _ = try app.addDir(child(&app, ml, "datasets"), &.{f("imagenet-subset.tar", 2 * G)});
    try app.dirError(child(&app, home, "Library"), "/Users/you/Library/Mail: PermissionDenied");
    try app.logError("/Users/you/Library/Safari: 3 entries vanished or could not be read");
    app.files = 1_284_337;
    app.bytes = 64 * G;
    app.scanDone();
    return app;
}

const BG = "#1a1b26";
const FG = "#c0caf5";
const CW = 8.6; // cell width
const CH = 18.0; // cell height
const PAD = 16.0;
const BAR = 30.0; // window title bar

fn color(c: vaxis.Color, fallback: []const u8, buf: *[8]u8) []const u8 {
    return switch (c) {
        .default => fallback,
        .rgb => |rgb| std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch fallback,
        .index => |i| switch (i) {
            0 => BG,
            8 => "#565f89",
            else => fallback,
        },
    };
}

fn toSvg(arena: Allocator, screen: *vaxis.Screen, title: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = PAD * 2 + CW * @as(f64, @floatFromInt(screen.width));
    const h = BAR + PAD * 2 + CH * @as(f64, @floatFromInt(screen.height));
    try out.print(arena,
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d:.0}" height="{d:.0}" viewBox="0 0 {d:.0} {d:.0}">
        \\<rect width="100%" height="100%" rx="10" fill="{s}"/>
        \\<rect width="100%" height="{d:.0}" rx="10" fill="#16161e"/><rect y="{d:.0}" width="100%" height="10" fill="#16161e"/>
        \\<circle cx="18" cy="15" r="6" fill="#f7768e"/><circle cx="38" cy="15" r="6" fill="#e0af68"/><circle cx="58" cy="15" r="6" fill="#9ece6a"/>
        \\<text x="50%" y="19" fill="#565f89" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace" font-size="12" text-anchor="middle">{s}</text>
        \\<g font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'DejaVu Sans Mono',monospace" font-size="14" xml:space="preserve">
        \\
    , .{ w, h, w, h, BG, BAR, BAR - 10, title });

    for (0..screen.height) |row| {
        var col: usize = 0;
        while (col < screen.width) {
            // A run: consecutive cells with the same style.
            const start = col;
            const style = screen.buf[row * screen.width + col].style;
            var text: std.ArrayList(u8) = .empty;
            while (col < screen.width and screen.buf[row * screen.width + col].style.eql(style)) : (col += 1) {
                const g = screen.buf[row * screen.width + col].char.grapheme;
                try escape(arena, &text, if (g.len == 0) " " else g);
            }
            const x = PAD + CW * @as(f64, @floatFromInt(start));
            const y = BAR + PAD + CH * @as(f64, @floatFromInt(row));
            const n: f64 = @floatFromInt(col - start);
            var bb: [8]u8 = undefined;
            var fb: [8]u8 = undefined;
            if (style.bg != .default) {
                try out.print(arena, "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" fill=\"{s}\"/>\n", .{ x, y, CW * n, CH, color(style.bg, BG, &bb) });
            }
            if (std.mem.trim(u8, text.items, " ").len == 0) continue;
            try out.print(arena, "<text x=\"{d:.1}\" y=\"{d:.1}\" textLength=\"{d:.1}\" lengthAdjust=\"spacingAndGlyphs\" fill=\"{s}\"{s}>{s}</text>\n", .{
                x, y + CH * 0.75, CW * n, color(style.fg, FG, &fb), if (style.bold) " font-weight=\"bold\"" else "", text.items,
            });
        }
    }
    try out.appendSlice(arena, "</g>\n</svg>\n");
    return out.items;
}

fn escape(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |b| switch (b) {
        '&' => try out.appendSlice(arena, "&amp;"),
        '<' => try out.appendSlice(arena, "&lt;"),
        '>' => try out.appendSlice(arena, "&gt;"),
        // Non-breaking space: SVG renderers collapse runs of normal spaces, which breaks the column grid.
        ' ' => try out.appendSlice(arena, "\u{a0}"),
        else => try out.append(arena, b),
    };
}
