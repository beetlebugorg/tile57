//! filemap — a read-only memory map of a file, cross-platform.
//!
//! Zig std has no portable mmap: `std.posix.mmap` is POSIX-only (its PROT/MAP flag
//! types are `void` on Windows, so it won't even compile there), and `std.os.windows`
//! doesn't bind the file-mapping calls. So this maps via `std.posix.mmap` on POSIX and
//! `CreateFileMapping`/`MapViewOfFile` (declared below) on Windows — the SAME lazily
//! paged, page-cache-shared view on both, so a whole chart library can be open without
//! being resident. Callers pass a file handle (`std.posix.fd_t` is `HANDLE` on Windows)
//! and a length; the mapping outlives the file handle on both platforms.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const page = std.heap.page_size_min;

const PAGE_READONLY: windows.DWORD = 0x02;
const FILE_MAP_READ: windows.DWORD = 0x0004;
extern "kernel32" fn CreateFileMappingW(
    hFile: windows.HANDLE,
    lpAttributes: ?*anyopaque,
    flProtect: windows.DWORD,
    dwMaximumSizeHigh: windows.DWORD,
    dwMaximumSizeLow: windows.DWORD,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    dwFileOffsetHigh: windows.DWORD,
    dwFileOffsetLow: windows.DWORD,
    dwNumberOfBytesToMap: usize,
) callconv(.winapi) ?windows.LPVOID;
extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: windows.LPCVOID) callconv(.winapi) windows.BOOL;

/// Map the first `len` bytes of `handle` read-only (`len` must be > 0). Release with
/// `unmap`. The file handle may be closed once this returns — the view keeps the
/// underlying data alive on both POSIX (mmap) and Windows (MapViewOfFile).
pub fn mapReadonly(handle: std.posix.fd_t, len: usize) error{IoFailed}![]align(page) const u8 {
    if (builtin.os.tag == .windows) {
        const h = CreateFileMappingW(handle, null, PAGE_READONLY, 0, 0, null) orelse return error.IoFailed;
        defer windows.CloseHandle(h); // the mapped view keeps the section alive after this
        const p = MapViewOfFile(h, FILE_MAP_READ, 0, 0, 0) orelse return error.IoFailed;
        // MapViewOfFile is aligned to the 64 KB allocation granularity, so >= page align.
        const base: [*]align(page) const u8 = @ptrCast(@alignCast(p));
        return base[0..len];
    }
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, handle, 0) catch
        return error.IoFailed;
}

/// Release a mapping returned by `mapReadonly`.
pub fn unmap(m: []align(page) const u8) void {
    if (builtin.os.tag == .windows) {
        _ = UnmapViewOfFile(@ptrCast(m.ptr));
    } else {
        std.posix.munmap(m);
    }
}
