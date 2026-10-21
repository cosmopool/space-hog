//! Shared terminal frontend: draws a `core.View` with libvaxis and turns terminal input into `core.Key`s.
//! Mock 1 "classic yazi": path line, parent | current | preview columns, status bar.
const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core");
const Allocator = std.mem.Allocator;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    /// Posted by scan workers; just triggers a redraw.
    progress,
};

const HIGHLIGHT: vaxis.Color = .{ .rgb = .{ 0x7a, 0xa2, 0xf7 } };
const DIM: vaxis.Color = .{ .index = 8 };
const SEL_BG: vaxis.Color = .{ .rgb = .{ 0x2f, 0x3b, 0x63 } };
const WARN: vaxis.Color = .{ .rgb = .{ 0xe0, 0xaf, 0x68 } };
const OK: vaxis.Color = .{ .rgb = .{ 0x9e, 0xce, 0x6a } };
const DANGER: vaxis.Color = .{ .rgb = .{ 0xf7, 0x76, 0x8e } };

pub const Tui = struct {
    gpa: Allocator,
    io: std.Io,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    tty_buf: [4096]u8 = undefined,
    scroll: Scroll = .{},
    resize_handler: bool = false,

    /// `t` must stay at a stable address (the loop keeps pointers into it).
    pub fn init(t: *Tui, gpa: Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
        t.* = .{ .gpa = gpa, .io = io, .tty = undefined, .vx = undefined, .loop = undefined };
        t.tty = try vaxis.Tty.init(io, &t.tty_buf);
        errdefer t.tty.deinit();
        t.vx = try vaxis.init(io, gpa, env, .{});
        t.loop = .init(io, &t.tty, &t.vx);
        try t.loop.start();
        try t.vx.enterAltScreen(t.tty.writer());
        try t.vx.queryTerminal(t.tty.writer(), .fromSeconds(1));
        if (!t.vx.state.in_band_resize) {
            try t.loop.installResizeHandler();
            t.resize_handler = true;
        }
    }

    pub fn deinit(t: *Tui) void {
        if (t.resize_handler) t.loop.uninstallResizeHandler();
        t.loop.stop();
        t.vx.deinit(t.gpa, t.tty.writer());
        t.tty.deinit();
    }

    pub fn next(t: *Tui) !Event {
        const ev = try t.loop.nextEvent();
        if (ev == .winsize) try t.vx.resize(t.gpa, t.tty.writer(), ev.winsize);
        return ev;
    }

    /// Thread-safe wake-up from scan workers; drops the event if the queue is full.
    pub fn wake(ctx: *anyopaque) void {
        const t: *Tui = @ptrCast(@alignCast(ctx));
        _ = t.loop.tryPostEvent(.progress) catch {};
    }

    /// Rows available for a column (used to turn "half page" into a row count).
    pub fn pageRows(t: *Tui) usize {
        return t.vx.window().height -| 4;
    }

    pub fn draw(t: *Tui, arena: Allocator, v: core.View) !void {
        try paint(arena, t.vx.window(), v, &t.scroll);
        try t.vx.render(t.tty.writer());
    }
};

/// First visible row of the current column, kept across frames so the cursor stays on screen.
/// Resets when the directory changes.
pub const Scroll = struct {
    offset: usize = 0,
    path_hash: u64 = 0,

    fn update(s: *Scroll, v: core.View, h: usize) void {
        const hash = std.hash.Wyhash.hash(0, v.path);
        if (hash != s.path_hash) {
            s.path_hash = hash;
            s.offset = 0;
        }
        if (h == 0) return;
        if (v.cursor < s.offset) s.offset = v.cursor;
        if (v.cursor >= s.offset + h) s.offset = v.cursor + 1 - h;
        if (s.offset > v.current.len -| h) s.offset = v.current.len -| h;
    }
};

/// Draws `v` into `win` (any size, including tiny or zero). Pure apart from `scroll`; the app renders the
/// result to the terminal, tests inspect the cells.
pub fn paint(arena: Allocator, win: vaxis.Window, v: core.View, scroll: *Scroll) !void {
    win.clear();
    if (win.width < 10 or win.height < 5) return;

    printLine(win, 0, 1, &.{.{ .text = try clean(arena, v.path), .style = .{ .fg = DIM } }});
    const body_h = win.height - 3;
    const body = win.child(.{ .y_off = 1, .height = body_h + 1 });
    hline(body, 0, win.width);
    hline(body, body_h, win.width);

    if (v.mode == .log) {
        try drawLog(arena, body.child(.{ .y_off = 1, .height = body_h - 1 }), v);
    } else {
        const pw = win.width / 5;
        const cw = (win.width - pw) / 2;
        const rows_h = body_h - 1;
        const cols = [_]struct { x: u16, w: u16 }{ .{ .x = 0, .w = pw }, .{ .x = pw + 1, .w = cw }, .{ .x = pw + cw + 2, .w = win.width -| (pw + cw + 2) } };
        vline(body, pw, 1, rows_h);
        vline(body, pw + cw + 1, 1, rows_h);

        scroll.update(v, rows_h);
        const parent_off = v.parent_cursor -| (rows_h / 2);
        try drawColumn(arena, body.child(.{ .x_off = cols[0].x, .y_off = 1, .width = cols[0].w, .height = rows_h }), v.parent, parent_off);
        try drawColumn(arena, body.child(.{ .x_off = cols[1].x, .y_off = 1, .width = cols[1].w, .height = rows_h }), v.current, scroll.offset);
        try drawColumn(arena, body.child(.{ .x_off = cols[2].x, .y_off = 1, .width = cols[2].w, .height = rows_h }), v.preview, 0);
    }

    try drawStatus(arena, win.child(.{ .y_off = win.height - 1, .height = 1 }), v);
    if (v.prompt) |p| try drawPrompt(arena, win, p, v.status.dry_run);
}

/// Converts a vaxis key press into a core key. Returns null for keys the core does not care about.
pub fn coreKey(k: vaxis.Key) ?core.Key {
    const K = vaxis.Key;
    const special = [_]struct { u21, u21 }{
        .{ K.up, core.Key.UP },       .{ K.down, core.Key.DOWN },   .{ K.left, core.Key.LEFT },
        .{ K.right, core.Key.RIGHT }, .{ K.escape, core.Key.ESC }, .{ K.enter, core.Key.ENTER },
        .{ K.tab, core.Key.TAB },
    };
    // Alt/Super/Hyper/Meta combos are never bound: ignore them so e.g. Alt+x can't trash.
    if (k.mods.alt or k.mods.super or k.mods.hyper or k.mods.meta) return null;
    for (special) |s| if (k.codepoint == s[0]) return .{ .code = s[1], .ctrl = k.mods.ctrl };
    if (k.mods.ctrl) {
        // Ctrl only combines with letters; anything else would alias an unrelated ASCII control key.
        if (k.codepoint > 0x7f or !std.ascii.isAlphabetic(@intCast(k.codepoint))) return null;
        return .{ .code = std.ascii.toLower(@intCast(k.codepoint)), .ctrl = true };
    }
    if (k.text) |text| if (text.len > 0) {
        const n = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
        if (n > text.len) return null;
        return .{ .code = std.unicode.utf8Decode(text[0..n]) catch return null };
    };
    if (k.mods.shift) if (k.shifted_codepoint) |cp| return .{ .code = cp };
    if (k.codepoint >= 0xE000 and k.codepoint < 0xF900) return null;
    return .{ .code = k.codepoint };
}

/// Human-readable size like `du -h` (shared with the core's log messages).
pub const fmtSize = core.fmtSize;

/// Makes an untrusted name safe to print: control bytes, escape sequences and invalid UTF-8 become `?`.
pub fn clean(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, name.len);
    var i: usize = 0;
    while (i < name.len) {
        const n = std.unicode.utf8ByteSequenceLength(name[i]) catch {
            try out.append(arena, '?');
            i += 1;
            continue;
        };
        if (i + n > name.len) {
            try out.append(arena, '?');
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(name[i .. i + n]) catch {
            try out.append(arena, '?');
            i += 1;
            continue;
        };
        if (unsafeCodepoint(cp)) {
            try out.append(arena, '?');
        } else {
            try out.appendSlice(arena, name[i .. i + n]);
        }
        i += n;
    }
    return out.items;
}

/// Control characters, line separators, and invisible or direction-changing characters (bidi controls,
/// zero-width) that could make a name look like another one in the delete prompt.
fn unsafeCodepoint(cp: u21) bool {
    return cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0) or
        cp == 0x2028 or cp == 0x2029 or
        (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069) or
        cp == 0x200e or cp == 0x200f or cp == 0x061c or
        (cp >= 0x200b and cp <= 0x200d) or cp == 0xfeff;
}

fn rowStyle(r: core.Row) vaxis.Style {
    var s: vaxis.Style = .{};
    switch (r.style) {
        .highlight => s.fg = HIGHLIGHT,
        .dim => s.fg = DIM,
        .normal => {},
    }
    if (r.unscanned) s.fg = DIM;
    if (r.selected) s.bg = SEL_BG;
    return s;
}

fn drawColumn(arena: Allocator, win: vaxis.Window, rows: []const core.Row, offset: usize) !void {
    if (win.width < 4) return;
    const visible = rows[@min(offset, rows.len)..];
    for (visible[0..@min(visible.len, win.height)], 0..) |r, i| {
        const y: u16 = @intCast(i);
        const style = rowStyle(r);
        if (r.selected) win.child(.{ .y_off = y, .height = 1 }).fill(.{ .style = style });
        var buf: [16]u8 = undefined;
        const size = if (r.unscanned) "" else fmtSize(&buf, r.size);
        const size_text = try std.fmt.allocPrint(arena, "{s}{s}{s} ", .{ size, if (r.incomplete) "?" else "", if (r.shared) "~" else "" });
        const size_w: u16 = @intCast(@min(size_text.len, win.width / 2));
        const name_w = win.width - size_w;
        const name = try clean(arena, r.name);
        _ = win.child(.{ .x_off = 1, .y_off = y, .width = name_w -| 2, .height = 1 }).printSegment(.{ .text = name, .style = style }, .{ .wrap = .none });
        _ = win.child(.{ .x_off = name_w, .y_off = y, .width = size_w, .height = 1 }).printSegment(.{ .text = size_text, .style = style }, .{ .wrap = .none });
    }
}

fn drawStatus(arena: Allocator, win: vaxis.Window, v: core.View) !void {
    var buf: [16]u8 = undefined;
    const bytes = fmtSize(&buf, v.status.bytes);
    const left = if (v.status.scan_done)
        try std.fmt.allocPrint(arena, " ✓ {d} files · {s}", .{ v.status.files, bytes })
    else
        try std.fmt.allocPrint(arena, " ⟳ scanning {d} files · {s}", .{ v.status.files, bytes });
    var col: u16 = 0;
    if (v.status.dry_run) col = win.printSegment(.{ .text = " DRY RUN ", .style = .{ .fg = .{ .index = 0 }, .bg = WARN, .bold = true } }, .{ .wrap = .none }).col;
    if (v.status.last_dry_run.len > 0) {
        // At most half the bar, so the scan stats stay visible.
        const note = try clean(arena, v.status.last_dry_run["dry run: ".len..]);
        const room = (win.width / 2) -| col;
        const w = win.child(.{ .x_off = col, .width = room, .height = 1 });
        col += w.printSegment(.{ .text = try std.fmt.allocPrint(arena, " {s}", .{note}), .style = .{ .fg = WARN } }, .{ .wrap = .none }).col;
    }
    col = win.printSegment(.{ .text = left, .style = .{ .fg = if (v.status.scan_done) OK else WARN } }, .{ .wrap = .none, .col_offset = col }).col;
    if (v.status.errors > 0) {
        const e = try std.fmt.allocPrint(arena, "   ! {d} unreadable", .{v.status.errors});
        col = win.printSegment(.{ .text = e, .style = .{ .fg = DANGER } }, .{ .wrap = .none, .col_offset = col }).col;
    }
    if (v.status.pending.len > 0) {
        const p = try std.fmt.allocPrint(arena, "   {s}", .{v.status.pending});
        col = win.printSegment(.{ .text = p }, .{ .wrap = .none, .col_offset = col }).col;
    }
    var buf2: [16]u8 = undefined;
    const right = try std.fmt.allocPrint(arena, "{d}/{d}   {s}   x trash  X rm -r  q quit ", .{
        if (v.current.len == 0) 0 else v.cursor + 1, v.current.len, fmtSize(&buf2, v.size),
    });
    const w: u16 = @intCast(@min(right.len, win.width));
    if (@as(u32, col) + w < win.width) _ = win.printSegment(.{ .text = right, .style = .{ .fg = DIM } }, .{ .wrap = .none, .col_offset = win.width - w });
}

fn drawLog(arena: Allocator, win: vaxis.Window, v: core.View) !void {
    const off = v.log_cursor -| (win.height / 2);
    const lines = v.log[@min(off, v.log.len)..];
    for (lines[0..@min(lines.len, win.height)], 0..) |line, i| {
        const sel = off + i == v.log_cursor;
        const style: vaxis.Style = if (sel) .{ .bg = SEL_BG } else .{};
        const row = win.child(.{ .y_off = @intCast(i), .height = 1 });
        if (sel) row.fill(.{ .style = style });
        _ = row.printSegment(.{ .text = try clean(arena, line), .style = style }, .{ .wrap = .none, .col_offset = 1 });
    }
    if (v.log.len == 0) _ = win.printSegment(.{ .text = " no errors", .style = .{ .fg = DIM } }, .{ .wrap = .none });
}

fn drawPrompt(arena: Allocator, win: vaxis.Window, p: core.view.Prompt, dry_run: bool) !void {
    const w: u16 = @min(win.width -| 4, 60);
    const box = win.child(.{
        .x_off = @intCast((win.width - w) / 2),
        .y_off = @intCast(win.height / 2 -| 3),
        .width = w,
        .height = 7,
        .border = .{ .where = .all, .style = .{ .fg = DANGER } },
    });
    box.clear();
    var buf: [16]u8 = undefined;
    _ = box.printSegment(.{ .text = if (dry_run) " DRY RUN: would delete (rm -r)" else " Delete permanently (rm -r)?", .style = .{ .bold = true } }, .{ .wrap = .none });
    _ = box.printSegment(.{ .text = try clean(arena, p.path) }, .{ .wrap = .none, .row_offset = 1, .col_offset = 1 });
    _ = box.printSegment(.{ .text = fmtSize(&buf, p.size) }, .{ .wrap = .none, .row_offset = 2, .col_offset = 1 });
    if (p.shared) _ = box.printSegment(.{ .text = " some files are hardlinked elsewhere; may free less", .style = .{ .fg = WARN } }, .{ .wrap = .none, .row_offset = 3 });
    _ = box.printSegment(.{ .text = " y delete   any other key cancels", .style = .{ .fg = DIM } }, .{ .wrap = .none, .row_offset = if (p.shared) 4 else 3 });
}

fn hline(win: vaxis.Window, y: u16, w: u16) void {
    var x: u16 = 0;
    while (x < w) : (x += 1) win.writeCell(x, y, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{ .fg = DIM } });
}

fn vline(win: vaxis.Window, x: u16, y0: u16, h: u16) void {
    var y: u16 = 0;
    while (y < h) : (y += 1) win.writeCell(x, y0 + y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = .{ .fg = DIM } });
}

fn printLine(win: vaxis.Window, row: u16, col: u16, segs: []const vaxis.Segment) void {
    _ = win.print(segs, .{ .wrap = .none, .row_offset = row, .col_offset = col });
}
