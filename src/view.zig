//! Pure view model produced by `App.view()`. Everything is allocated in the arena passed to `view()`.
const tree = @import("tree.zig");
const rules = @import("rules.zig");

pub const Style = rules.Style;

pub const Row = struct {
    name: []const u8,
    size: u64,
    kind: tree.Kind,
    style: Style = .normal,
    selected: bool = false,
    /// Size is partial (unreadable somewhere below). Shown as `?` after the size.
    incomplete: bool = false,
    /// Contains hardlinked files: deleting it may free less than `size`. Shown as `~` after the size.
    shared: bool = false,
    /// Non-empty for another path to an already counted directory (e.g. a macOS firmlink): that path.
    alias_of: []const u8 = "",
    /// Listed but never scanned (the real parent of the scan root). Size is unknown.
    unscanned: bool = false,
};

pub const Mode = enum { normal, log };

pub const Prompt = struct {
    path: []const u8,
    size: u64,
    shared: bool = false,
};

pub const Status = struct {
    files: u64 = 0,
    bytes: u64 = 0,
    scan_done: bool = false,
    /// Started with `--dry-run`: nothing is ever trashed or deleted.
    dry_run: bool = false,
    /// Latest "dry run: would ..." note, so you see what would have been deleted without opening the log.
    last_dry_run: []const u8 = "",
    errors: usize = 0,
    /// Keys typed so far of an unfinished sequence (e.g. "g").
    pending: []const u8 = "",
};

pub const View = struct {
    mode: Mode = .normal,
    /// Full path of the current directory.
    path: []const u8 = "",
    /// Size of the current directory.
    size: u64 = 0,
    parent: []Row = &.{},
    current: []Row = &.{},
    preview: []Row = &.{},
    /// Index of the selected row in `parent` / `current` (0 when empty).
    parent_cursor: usize = 0,
    cursor: usize = 0,
    status: Status = .{},
    prompt: ?Prompt = null,
    /// Error log, oldest first (only filled in `.log` mode).
    log: []const []const u8 = &.{},
    log_cursor: usize = 0,
};
