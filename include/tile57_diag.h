/* tile57_diag.h — developer / bring-up diagnostics for libtile57.
 *
 * These entry points exercise the embedded Lua interpreter and the S-101
 * portrayal framework directly. They are NOT part of the embedding API
 * (tile57.h) — they back the chartplotter-render --s101* CLI subcommands
 * and the test suite. Hosts that just render charts do not need this header.
 */
#ifndef TILE57_DIAG_H
#define TILE57_DIAG_H

#ifdef __cplusplus
extern "C" {
#endif

/* Embedded Lua sanity checks. tile57_diag_lua_selftest runs a trivial chunk and
 * returns 42 on success (negative on error); tile57_diag_lua_version returns e.g.
 * "Lua 5.4". Together they prove the interpreter is embedded and linked. */
long tile57_diag_lua_selftest(void);
const char *tile57_diag_lua_version(void);

/* Load the S-101 framework (S100Scripting/PortrayalModel/PortrayalAPI/Default/
 * main) from a Rules directory in embedded Lua. Returns 0 on success, negative
 * on error (diagnostics to stderr). Validates Lua 5.4 compatibility. */
int tile57_diag_check_rules(const char *dir);

/* Run the S-101 framework with stub Host callbacks + an empty feature set,
 * proving it executes (not just loads) in embedded Lua. Returns 0 on success. */
int tile57_diag_run_framework(const char *dir);

/* Run the real DepthArea rule against a synthetic feature with a minimal
 * hardcoded catalogue; prints the emitted S-101 instruction stream to stderr.
 * Returns 0 on success. Proof-of-portrayal before the full Host binding. */
int tile57_diag_portray_demo(const char *dir);

#ifdef __cplusplus
}
#endif

#endif /* TILE57_DIAG_H */
