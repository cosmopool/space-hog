# Decisions

## D1. Guarding trash / rm -r against paths changed since the scan

**Problem.** Trash and `rm -r` act on a path rebuilt from the scanned tree (`/root/proj/build`). Between the
scan and the key press, something else can change the filesystem. If a parent directory is replaced by a
symlink (`proj -> /somewhere/else`), a plain path-based delete follows the link and removes
`/somewhere/else/build`, which was never shown to the user.

**Chosen: lighter check (parent components must not be symlinks).**
Right before trash or `rm -r`, `fsops.parentsUnchanged` `lstat`s every parent component of the target path
(not the target itself) and requires each to still be a real directory. The scan root is resolved with
`realpath` at startup, so a scanned path never legitimately contains a symlink above the target. On any
mismatch the action is refused, logged as `ParentChangedSinceScan`, and the parent is rescanned.

- Cost: one `lstat` per path component per delete; no extra memory.
- Covers: a parent swapped for a symlink, a parent removed, a parent replaced by a file.
- Does **not** cover: a parent directory replaced by a *different real directory* with the same name (e.g.
  `mv proj proj.old && mkdir proj && ...`). The delete then acts on the new directory at that path.
- There is still a small race between the check and the delete itself (no `openat` chain), so a swap in
  that window is not caught.
- Covered by `test/fsops_test.zig`: "a parent swapped for a symlink after the scan ...".

**Alternative (not chosen): verify identity before acting.**
Store each node's `dev + inode` at scan time (about 12 more bytes per node). Before trash / `rm -r`, walk
the path from the scan root with `openat(O_NOFOLLOW | O_DIRECTORY)` and check that every component still
has the recorded `dev + inode`; then delete relative to the final directory fd (`unlinkat`, `renameat`).

- Covers everything above, including a directory replaced by another real directory, and closes the
  check-then-act race because the delete runs on the verified fds.
- Costs more memory per node and a larger rewrite of trash / `rm -r` (fd-relative operations; `std.Io.Dir.deleteTree`
  could no longer be used as is).

Switch to the alternative if deletes ever need to be safe against concurrent modification by other
processes, not just against a stale view.
