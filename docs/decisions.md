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

## D2. Trash / rm -r never cross into another filesystem

**Problem.** The scan crosses mount points like `du` does, so a directory can contain a mounted volume.
`rm -r` on it would also delete the volume's contents.

**Chosen: refuse and log.** Before trash or `rm -r`, `fsops.noMountInside` walks the target subtree on disk
(no symlinks followed) and refuses if any directory has a different `st_dev` than the target. The log says
`<action> refused for <path>: contains mount point <child>`. Scanning still crosses mounts.

- Verified by hand on macOS with a disk image attached inside the target (`hdiutil attach -mountpoint`);
  not in the automated suite because creating a mount needs privileges or OS tools.
- Cost: one extra walk of the target subtree before deleting.

**Alternative (not chosen): `rm --one-file-system` behaviour.** Delete everything on the target's
filesystem and skip the mounted parts. Frees most of the space, but leaves a partly deleted tree and the
mount point directories behind, which is harder to reason about from the UI.

## D3. One directory reached by two paths is scanned and counted once

**Problem.** On macOS, `/Users`, `/Applications`, `/Library`, ... are firmlinks into the data volume, so
`/Users/me` and `/System/Volumes/Data/Users/me` are the same directory (same `st_dev` + `st_ino`). Firmlinks
are not symlinks, so "don't follow symlinks" does not stop it: re-rooting up to `/` scanned and counted the
home directory twice. Linux bind mounts cause the same thing.

**Chosen: dedupe directories by dev+inode; the second path becomes an alias.** The scanner keeps every
directory's `(dev, ino)` (from the `lstat` it already does per entry, plus `fstatat(fd, ".")` for the directory
being read, plus `registerLocked` for roots that enter the tree without being listed). A directory whose key is
already owned by a live node is marked with `App.markAlias`: it stays listed, dimmed, size 0, shown as
`= <path that is counted>`; it is not scanned, `l` does not enter it, and `x` / `X` are refused with a log line
pointing to the counted path. If the owner is rescanned or deleted, the next path found takes ownership.

- Covered by `test/scan_test.zig` "macOS firmlink: ..." (real firmlink, temp dir under `/Users`) and
  `test/core_test.zig` "an alias directory counts 0, ...".
- Which of the two paths is counted depends on scan order (first one read wins), like hardlinked files.

**Alternatives (not chosen):** hide the second path entirely; or keep it browsable with its real size but
excluded from parent totals (needs separate "shown" and "counted" sizes).
