/// Highlight rules for one directory's children.
pub const Style = enum(u2) { normal, highlight, dim };

pub const HIGHLIGHT_PCT = 80;
pub const DIM_PCT = 15;

/// `sizes` must be sorted descending. Highlights the smallest prefix whose sum reaches >= 80% of `parent_size`
/// (the row that crosses the line included). Rows outside that prefix under 15% of the parent are dimmed.
pub fn classify(parent_size: u64, sizes: []const u64, out: []Style) void {
    const parent: u128 = parent_size;
    var sum: u128 = 0;
    var reached = parent == 0;
    for (sizes, out) |size, *style| {
        if (!reached) {
            sum += size;
            reached = sum * 100 >= parent * HIGHLIGHT_PCT;
            style.* = .highlight;
        } else if (@as(u128, size) * 100 < parent * DIM_PCT) {
            style.* = .dim;
        } else {
            style.* = .normal;
        }
    }
}
