/*
 * Libc definitions wasi-libc declares but does not ship, needed to LINK the
 * embedded Lua on wasm32-wasi. Compiled only into the wasm engine (build.zig
 * addLua, wasm branch).
 */

#include <errno.h>
#include <stdio.h>

/*
 * wasi has no temp-file directory, so wasi-libc's stdio.h declares tmpfile()
 * without a definition. Lua's io.tmpfile links against it; a NULL return with
 * errno set becomes a clean `nil, "..."` result at the Lua level. Nothing in
 * the portrayal path opens temp files.
 */
FILE *tmpfile(void) {
        errno = ENOTSUP;
        return NULL;
}
