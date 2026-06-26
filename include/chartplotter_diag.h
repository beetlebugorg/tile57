/* chartplotter_diag.h — developer / bring-up diagnostics for libchartplotter.
 *
 * These entry points exercise the embedded Lua interpreter and the S-101
 * portrayal framework directly. They are NOT part of the embedding API
 * (chartplotter.h) — they back the chartplotter-render --s101* CLI subcommands
 * and the test suite. Hosts that just render charts do not need this header.
 */
#ifndef CHARTPLOTTER_DIAG_H
#define CHARTPLOTTER_DIAG_H

#ifdef __cplusplus
extern "C" {
#endif

/* Embedded Lua sanity checks. chartplotter_diag_lua_selftest runs a trivial chunk and
 * returns 42 on success (negative on error); chartplotter_diag_lua_version returns e.g.
 * "Lua 5.4". Together they prove the interpreter is embedded and linked. */
long chartplotter_diag_lua_selftest(void);
const char *chartplotter_diag_lua_version(void);

/* Load the S-101 framework (S100Scripting/PortrayalModel/PortrayalAPI/Default/
 * main) from a Rules directory in embedded Lua. Returns 0 on success, negative
 * on error (diagnostics to stderr). Validates Lua 5.4 compatibility. */
int chartplotter_diag_check_rules(const char *dir);

/* Run the S-101 framework with stub Host callbacks + an empty feature set,
 * proving it executes (not just loads) in embedded Lua. Returns 0 on success. */
int chartplotter_diag_run_framework(const char *dir);

/* Run the real DepthArea rule against a synthetic feature with a minimal
 * hardcoded catalogue; prints the emitted S-101 instruction stream to stderr.
 * Returns 0 on success. Proof-of-portrayal before the full Host binding. */
int chartplotter_diag_portray_demo(const char *dir);

#ifdef __cplusplus
}
#endif

#endif /* CHARTPLOTTER_DIAG_H */
