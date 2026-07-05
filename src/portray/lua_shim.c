/* lua_shim.c — tiny C bridge to the embedded Lua 5.4, compiled into
 * libtile57.a. Lua's convenience macros (luaL_dostring, lua_pcall, ...) are
 * easiest to use from C, so the S-101 portrayal entry points live here and are
 * called from Zig via the C ABI.
 *
 * For now this is just a self-test proving Lua compiles, links, and runs inside
 * the C++ host. The real S-101 rule evaluation will grow here (or move to a Zig
 * @cImport of lua.h) at M6d. */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Accessors implemented in Zig (portray.zig) over the adapted cell features. */
extern size_t tgp_count(void);
extern const char *tgp_code(size_t i, size_t *len);
extern const char *tgp_primitive(size_t i, size_t *len);
extern const char *tgp_simple(size_t i, const char *path, size_t plen,
                              const char *code, size_t clen, size_t *len);
extern size_t tgp_complex_count(size_t i, const char *path, size_t plen,
                                const char *code, size_t clen);
extern void tgp_emit(size_t i, const char *instr, size_t len);
extern size_t tgp_points_count(size_t i);
extern void tgp_point(size_t i, size_t j, double *x, double *y, double *z);
extern size_t tgp_colocated(size_t i, size_t *out, size_t max);
extern size_t tgp_assoc_features(size_t i, const char *assoc, size_t assoc_len,
                                 const char *role, size_t role_len,
                                 size_t *out, size_t max);

/* Catalogue accessors implemented in Zig (catalogue.zig). */
extern size_t tgc_feature_count(void);
extern const char *tgc_feature_code(size_t i, size_t *len);
extern size_t tgc_simple_count(void);
extern const char *tgc_simple_code(size_t i, size_t *len);
extern size_t tgc_complex_count(void);
extern const char *tgc_complex_code(size_t i, size_t *len);
extern size_t tgc_info_count(void);
extern const char *tgc_info_code(size_t i, size_t *len);
extern size_t tgc_role_count(void);
extern const char *tgc_role_code(size_t i, size_t *len);
extern size_t tgc_feature_assoc_count(void);
extern const char *tgc_feature_assoc_code(size_t i, size_t *len);
extern size_t tgc_info_assoc_count(void);
extern const char *tgc_info_assoc_code(size_t i, size_t *len);
extern size_t tgc_feature_binding_count(const char *code, size_t code_len);
extern size_t tgc_complex_binding_count(const char *code, size_t code_len);
extern size_t tgc_info_binding_count(const char *code, size_t code_len);
extern void tgc_binding(unsigned char kind, const char *code, size_t code_len, size_t j,
                        const char **ref, size_t *ref_len, int *lower, int *upper);
extern const char *tgc_simple_valuetype(const char *code, size_t code_len, size_t *len);

/* Embedded S-101 Lua rule source by `require` name (rules_embed.zig). Returns the
 * source bytes (or NULL if the module isn't embedded) so the rules can be loaded
 * from memory with no on-disk catalogue. */
extern const char *tg_embedded_lua(const char *name, size_t nlen, size_t *out_len);

/* Run a trivial Lua chunk and return its integer result, or a negative error.
 * Used to verify the embedded interpreter end to end. */
long tile57_diag_lua_selftest(void) {
    lua_State *L = luaL_newstate();
    if (!L) return -1;
    luaL_openlibs(L);
    long result = -2;
    if (luaL_dostring(L, "return 6 * 7") == LUA_OK) {
        if (lua_isinteger(L, -1)) {
            result = (long)lua_tointeger(L, -1);
        }
    }
    lua_close(L);
    return result;
}

/* The embedded Lua version string (e.g. "Lua 5.4"). */
const char *tile57_diag_lua_version(void) { return LUA_VERSION; }

/* Value of the TILE57_S101_RULES env var (S-101 rules dir), or NULL. (Zig
 * 0.16's env access is behind Io; reading it here keeps the rules lookup simple.)
 * Used only as a fallback when a caller's rules_dir argument is NULL. */
const char *tg_env_rules(void) { return getenv("TILE57_S101_RULES"); }

/* Suppress the per-cell "[s101] portrayed …" stderr summary. Set once before a
 * parallel bake (many threads would otherwise garble the progress output); read
 * read-only by tg_portray_run thereafter. */
static int g_portray_quiet = 0;
void tg_set_quiet(int q) { g_portray_quiet = q; }

/* TILE57_DEBUG env gate (read once, cached). When set (and not "0"), the framework Debug
 * channel (l_debug_entry) and the per-feature QUESMRK1 diagnostic (Zig tgp_emit) print to
 * stderr; default off, so a running server/bake isn't flooded by a chart's latent per-
 * feature rule errors. Exported for the Zig side. */
int tg_debug_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char *e = getenv("TILE57_DEBUG");
        enabled = (e && e[0] && e[0] != '0') ? 1 : 0;
    }
    return enabled;
}

/* S-101 context parameters for one tg_portray_run pass — the values the
 * driver's cp() lines hand to the rules. Field order/types mirror the Zig
 * extern struct in portray.zig (keep in sync). A NULL ctx means the DEFAULTS
 * below, which reproduce the fixed bake context byte-for-byte; a native
 * render passes the mariner's real settings. */
typedef struct tg_portray_ctx {
    int plain_boundaries;      /* S-52 §8.6.1 boundary symbolization */
    int simplified_symbols;    /* S-52 §11.2.2 point-symbol style */
    int radar_overlay;
    int four_shades;
    int full_light_lines;
    int ignore_scale_minimum;
    int shallow_water_dangers;
    double safety_contour;
    double safety_depth;
    double shallow_contour;
    double deep_contour;
    double safety_height;
} tg_portray_ctx;

static const tg_portray_ctx tg_default_ctx = {
    /* bools */ 0, 0, 0, 1, 0, 0, 0,
    /* reals */ 30, 30, 2, 30, 0,
};

/* Push the context into Lua globals for the driver's cp() lines. Reals are
 * pre-formatted with %g so the default context yields the exact strings the
 * old static driver used ('30', '2', '0') — byte-identical rule behavior. */
static void tg_set_ctx_globals(lua_State *L, const tg_portray_ctx *ctx) {
    char num[64];
#define TG_SET_BOOL(name, v) do { lua_pushboolean(L, (v)); lua_setglobal(L, name); } while (0)
#define TG_SET_REAL(name, v) do { snprintf(num, sizeof num, "%g", (v)); lua_pushstring(L, num); lua_setglobal(L, name); } while (0)
    TG_SET_BOOL("PLAIN_BOUNDARIES", ctx->plain_boundaries);
    TG_SET_BOOL("SIMPLIFIED_SYMBOLS", ctx->simplified_symbols);
    TG_SET_BOOL("RADAR_OVERLAY", ctx->radar_overlay);
    TG_SET_BOOL("FOUR_SHADES", ctx->four_shades);
    TG_SET_BOOL("FULL_LIGHT_LINES", ctx->full_light_lines);
    TG_SET_BOOL("IGNORE_SCALE_MINIMUM", ctx->ignore_scale_minimum);
    TG_SET_BOOL("SHALLOW_WATER_DANGERS", ctx->shallow_water_dangers);
    TG_SET_REAL("SAFETY_CONTOUR", ctx->safety_contour);
    TG_SET_REAL("SAFETY_DEPTH", ctx->safety_depth);
    TG_SET_REAL("SHALLOW_CONTOUR", ctx->shallow_contour);
    TG_SET_REAL("DEEP_CONTOUR", ctx->deep_contour);
    TG_SET_REAL("SAFETY_HEIGHT", ctx->safety_height);
#undef TG_SET_BOOL
#undef TG_SET_REAL
}

/* Stub Host* callbacks (used to prove the framework EXECUTES, not just loads).
 * The real ones, backed by the Zig S-57 cell + catalogue, replace these. */
static int l_empty_table(lua_State *L) {
    lua_newtable(L);
    return 1;
}
static int l_noop(lua_State *L) {
    (void)L;
    return 0;
}
/* HostDebuggerEntry(kind, message, ...): surface the framework's Debug channel, but ONLY
 * when the TILE57_DEBUG env var is set (default off — a running server/bake stays silent).
 * Enabled, it prints 'first_chance_error' (S100Scripting overrides the global error() to
 * raise this on EVERY error — the cause of every QUESMRK1 "?") and 'trace' (main.lua names
 * the class it fell back to Default for). Off by default because a chart carrying a handful
 * of latent per-feature rule errors floods the log as tiles re-portray — the many identical
 * "Invalid primitive type ..." lines are one such standard rule guard. Diagnose a "?" with:
 *   TILE57_DEBUG=1 tile57 bake <cell.000> -o /tmp/x 2>&1 | grep '\[s101:'
 * Performance ('*_performance') and 'break' entries are always ignored. */
static int l_debug_entry(lua_State *L) {
    if (!tg_debug_enabled()) return 0;
    const char *kind = lua_tostring(L, 1);
    if (!kind) return 0;
    int is_err = strcmp(kind, "first_chance_error") == 0;
    if (is_err || strcmp(kind, "trace") == 0) {
        const char *msg = lua_tostring(L, 2);
        /* The Lua-5.4-vs-5.1 EqMetaMethod note (main.lua) fires once per lua_State — i.e.
         * per cell/thread — benign and high-volume, so drop it to keep the channel focused. */
        if (msg && strstr(msg, "Non-standard Lua processor")) return 0;
        fprintf(stderr, "[s101:%s] %s\n", is_err ? "error" : "trace", msg ? msg : "");
    }
    return 0;
}

static void register_host_stubs(lua_State *L) {
    static const char *empties[] = {
        "HostGetFeatureIDs", "HostGetFeatureTypeCodes", "HostGetInformationTypeCodes",
        "HostGetSimpleAttributeTypeCodes", "HostGetComplexAttributeTypeCodes",
        "HostGetRoleTypeCodes", "HostGetInformationAssociationTypeCodes",
        "HostGetFeatureAssociationTypeCodes", 0};
    static const char *noops[] = {
        "HostDebuggerEntry", "HostPortrayalEmit", "HostGetFeatureTypeInfo",
        "HostGetSimpleAttributeTypeInfo", "HostGetInformationTypeInfo",
        "HostGetComplexAttributeTypeInfo", "HostFeatureGetCode", "HostFeaturePrimitive",
        "HostFeaturePoints", "HostGetSpatial", "HostFeatureGetSimpleAttribute",
        "HostFeatureGetSpatialAssociations", "HostFeatureGetAssociatedFeatureIDs",
        "HostFeatureGetAssociatedInformationIDs", "HostSpatialGetAssociatedFeatureIDs",
        "HostSpatialGetAssociatedInformationIDs", "HostInformationTypeGetCode",
        "HostInformationTypeGetSimpleAttribute", "HostInformationTypeGetComplexAttributeCount",
        "HostFeatureGetComplexAttributeCount", "HostGetComplexAttributeCount", 0};
    for (int i = 0; empties[i]; i++) lua_register(L, empties[i], l_empty_table);
    for (int i = 0; noops[i]; i++) lua_register(L, noops[i], l_noop);
}

/* package.searchers entry that loads S-101 rule modules embedded in the binary
 * (tg_embedded_lua) rather than from the filesystem. Installed as the LAST
 * searcher, so an explicit on-disk rules dir (package.path, set from a --rules
 * flag or the vendored catalogue) still wins; this serves the rules when no such
 * directory is present — i.e. when tile57 runs as a standalone binary. Returns 2
 * (loader chunk + the module name) on a hit, or 1 (an explanatory string Lua
 * folds into the "module 'X' not found" message) on a miss. */
static int embedded_lua_searcher(lua_State *L) {
    size_t nlen = 0;
    const char *name = luaL_checklstring(L, 1, &nlen);
    size_t len = 0;
    const char *src = tg_embedded_lua(name, nlen, &len);
    if (!src) {
        /* Lua's own formatter (not libc printf) — folded into "module 'x' not found". */
        lua_pushfstring(L, "\n\tno embedded module '%s'", name);
        return 1;
    }
    /* Chunk name "@<name>.lua" ('@' => Lua shows it as a file path in tracebacks),
     * built with bounded memcpy — NOT snprintf: this runs on the baker's worker
     * threads, and musl's vfprintf is unsafe there (it crashed under parallel load). */
    char chunk[160];
    size_t n = nlen < sizeof(chunk) - 6 ? nlen : sizeof(chunk) - 6;
    chunk[0] = '@';
    memcpy(chunk + 1, name, n);
    memcpy(chunk + 1 + n, ".lua", 4);
    chunk[1 + n + 4] = '\0';
    if (luaL_loadbuffer(L, src, len, chunk) != LUA_OK)
        return lua_error(L); /* loader error already on the stack */
    lua_pushstring(L, name); /* passed to the loader as its 2nd arg, like the file searcher */
    return 2;
}

/* Append embedded_lua_searcher to package.searchers (after the default
 * filesystem searchers, so an on-disk rules dir takes precedence). Call once per
 * state, after luaL_openlibs (which creates the package library). */
static void install_embedded_searcher(lua_State *L) {
    lua_getglobal(L, "package");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
    lua_getfield(L, -1, "searchers");
    if (!lua_istable(L, -1)) { lua_pop(L, 2); return; }
    lua_Integer n = (lua_Integer)lua_rawlen(L, -1);
    lua_pushcfunction(L, embedded_lua_searcher);
    lua_rawseti(L, -2, n + 1);
    lua_pop(L, 2); /* searchers, package */
}

/* Prove the framework EXECUTES in embedded Lua 5.4: with stub Host callbacks and
 * an empty feature set, initialize the portrayal context and report the
 * FeaturePortrayalItems count (0). Returns 0 on success, negative on error. */
int tile57_diag_run_framework(const char *dir) {
    lua_State *L = luaL_newstate();
    if (!L) return -100;
    luaL_openlibs(L);
    install_embedded_searcher(L); /* embedded rules fall back when `dir` has none */
    char buf[8192];
    snprintf(buf, sizeof buf, "package.path = '%s/?.lua;' .. package.path", dir);
    int rc = 0;
    if (luaL_dostring(L, buf) != LUA_OK) {
        fprintf(stderr, "[s101] package.path: %s\n", lua_tostring(L, -1));
        rc = -1;
    } else {
        register_host_stubs(L);
        if (luaL_dostring(L,
                "require 'S100Scripting'; require 'PortrayalModel'; "
                "require 'PortrayalAPI'; require 'Default'; require 'main'") != LUA_OK) {
            fprintf(stderr, "[s101] framework load: %s\n", lua_tostring(L, -1));
            rc = -2;
        } else if (luaL_dostring(L,
                       "PortrayalInitializeContextParameters({Type='array:ContextParameter'}); "
                       "return #portrayalContext.FeaturePortrayalItems") != LUA_OK) {
            fprintf(stderr, "[s101] framework run: %s\n", lua_tostring(L, -1));
            rc = -3;
        } else {
            fprintf(stderr, "[s101] framework EXECUTED OK in %s; FeaturePortrayalItems=%lld\n",
                    LUA_VERSION, (long long)lua_tointeger(L, -1));
        }
    }
    lua_close(L);
    return rc;
}

/* ---- minimal catalogue + one synthetic DepthArea feature ----------------
 * Enough of the Host* contract (hardcoded) to run the REAL DepthArea.lua rule
 * and prove it emits real S-101 instructions. The production binding replaces
 * these with the Zig s57.Cell + a parsed FeatureCatalogue. */

static int l_arr_DepthArea(lua_State *L) { /* HostGetFeatureTypeCodes */
    lua_newtable(L);
    lua_pushstring(L, "DepthArea");
    lua_rawseti(L, -2, 1);
    return 1;
}
static int l_arr_depth_attrs(lua_State *L) { /* HostGetSimpleAttributeTypeCodes */
    lua_newtable(L);
    lua_pushstring(L, "depthRangeMinimumValue");
    lua_rawseti(L, -2, 1);
    lua_pushstring(L, "depthRangeMaximumValue");
    lua_rawseti(L, -2, 2);
    return 1;
}
static void push_binding(lua_State *L, const char *name) {
    lua_newtable(L);
    lua_pushinteger(L, 1);
    lua_setfield(L, -2, "UpperMultiplicity");
    lua_pushinteger(L, 0);
    lua_setfield(L, -2, "LowerMultiplicity");
    lua_setfield(L, -2, name); /* bindings[name] = {...} (bindings table at -2) */
}
/* Add a guaranteed binding ONLY if the catalogue didn't already bind it (the
 * AttributeBindings table is at the stack top). Mirrors Go's withGuaranteed: a
 * blind push would clobber the catalogue's real multiplicity — e.g. it would
 * overwrite RadioCallingInPoint's array-valued orientationValue (Upper=2) with a
 * scalar (Upper=1), so the rule's feature.orientationValue[1] indexes a nil. */
static void push_binding_if_absent(lua_State *L, const char *name) {
    lua_getfield(L, -1, name); /* AttributeBindings[name] */
    int absent = lua_isnil(L, -1);
    lua_pop(L, 1);
    if (absent) push_binding(L, name);
}
static int l_feature_type_info(lua_State *L) { /* HostGetFeatureTypeInfo(code) */
    const char *code = luaL_checkstring(L, 1);
    lua_newtable(L);
    lua_pushstring(L, "FeatureTypeInfo");
    lua_setfield(L, -2, "Type");
    lua_pushstring(L, code);
    lua_setfield(L, -2, "Code");
    lua_newtable(L); /* AttributeBindings */
    push_binding(L, "depthRangeMinimumValue");
    push_binding(L, "depthRangeMaximumValue");
    lua_setfield(L, -2, "AttributeBindings");
    return 1;
}
static int l_simple_attr_info(lua_State *L) { /* HostGetSimpleAttributeTypeInfo(code) */
    const char *code = luaL_checkstring(L, 1);
    lua_newtable(L);
    lua_pushstring(L, "SimpleAttributeInfo");
    lua_setfield(L, -2, "Type");
    lua_pushstring(L, code);
    lua_setfield(L, -2, "Code");
    lua_pushstring(L, "real");
    lua_setfield(L, -2, "ValueType");
    return 1;
}
static int l_feature_ids(lua_State *L) {
    lua_newtable(L);
    lua_pushstring(L, "f1");
    lua_rawseti(L, -2, 1);
    return 1;
}
static int l_feature_code(lua_State *L) {
    (void)L;
    lua_pushstring(L, "DepthArea");
    return 1;
}
static int l_feature_primitive(lua_State *L) {
    (void)L;
    lua_pushstring(L, "Surface");
    return 1;
}
static int l_feature_points(lua_State *L) { /* small exterior ring (lon,lat,depth strings) */
    static const char *ring[][2] = {
        {"-76.50", "38.90"}, {"-76.40", "38.90"}, {"-76.40", "38.98"}, {"-76.50", "38.98"}};
    lua_newtable(L);
    for (int i = 0; i < 4; i++) {
        lua_newtable(L);
        lua_pushstring(L, ring[i][0]);
        lua_rawseti(L, -2, 1);
        lua_pushstring(L, ring[i][1]);
        lua_rawseti(L, -2, 2);
        lua_pushstring(L, "0");
        lua_rawseti(L, -2, 3);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}
static int l_feature_simple_attr(lua_State *L) { /* (id, path, code) -> {value} */
    const char *code = luaL_checkstring(L, 3);
    lua_newtable(L);
    if (strcmp(code, "depthRangeMinimumValue") == 0) {
        lua_pushstring(L, "5");
        lua_rawseti(L, -2, 1);
    } else if (strcmp(code, "depthRangeMaximumValue") == 0) {
        lua_pushstring(L, "10");
        lua_rawseti(L, -2, 1);
    }
    return 1;
}
static int l_zero(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}
static int l_true(lua_State *L) {
    lua_pushboolean(L, 1);
    return 1;
}
static int l_empty_string(lua_State *L) {
    lua_pushstring(L, "");
    return 1;
}

/* Run the REAL DepthArea rule against a synthetic feature; print the emitted
 * S-101 instruction stream. Proves the portrayal path end to end. */
int tile57_diag_portray_demo(const char *dir) {
    lua_State *L = luaL_newstate();
    if (!L) return -100;
    luaL_openlibs(L);
    install_embedded_searcher(L); /* embedded rules fall back when `dir` has none */
    char buf[8192];
    snprintf(buf, sizeof buf, "package.path = '%s/?.lua;' .. package.path", dir);
    if (luaL_dostring(L, buf) != LUA_OK) {
        fprintf(stderr, "[s101] package.path: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -1;
    }
    /* catalogue + feature Host* (real, minimal) */
    lua_register(L, "HostGetFeatureTypeCodes", l_arr_DepthArea);
    lua_register(L, "HostGetSimpleAttributeTypeCodes", l_arr_depth_attrs);
    lua_register(L, "HostGetFeatureTypeInfo", l_feature_type_info);
    lua_register(L, "HostGetSimpleAttributeTypeInfo", l_simple_attr_info);
    lua_register(L, "HostGetFeatureIDs", l_feature_ids);
    lua_register(L, "HostFeatureGetCode", l_feature_code);
    lua_register(L, "_HostFeaturePrimitive", l_feature_primitive);
    lua_register(L, "_HostFeaturePoints", l_feature_points);
    lua_register(L, "HostFeatureGetSimpleAttribute", l_feature_simple_attr);
    lua_register(L, "HostFeatureGetComplexAttributeCount", l_zero);
    lua_register(L, "HostPortrayalEmit", l_true);
    lua_register(L, "HostDebuggerEntry", l_debug_entry);
    /* empty catalogue tables */
    lua_register(L, "HostGetInformationTypeCodes", l_empty_table);
    lua_register(L, "HostGetComplexAttributeTypeCodes", l_empty_table);
    lua_register(L, "HostGetRoleTypeCodes", l_empty_table);
    lua_register(L, "HostGetInformationAssociationTypeCodes", l_empty_table);
    lua_register(L, "HostGetFeatureAssociationTypeCodes", l_empty_table);
    lua_register(L, "HostFeatureGetAssociatedFeatureIDs", l_empty_table);
    lua_register(L, "HostFeatureGetAssociatedInformationIDs", l_empty_table);
    lua_register(L, "HostSpatialGetAssociatedFeatureIDs", l_empty_table);
    lua_register(L, "HostSpatialGetAssociatedInformationIDs", l_empty_table);
    lua_register(L, "HostInformationTypeGetCode", l_empty_string);
    lua_register(L, "HostInformationTypeGetSimpleAttribute", l_empty_table);
    lua_register(L, "HostInformationTypeGetComplexAttributeCount", l_zero);

    if (luaL_dostring(L,
            "require 'S100Scripting'; require 'PortrayalModel'; "
            "require 'PortrayalAPI'; require 'Default'; require 'main'") != LUA_OK) {
        fprintf(stderr, "[s101] framework load: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -2;
    }
    /* spatial glue (surfaces -> exterior ring), mirrors the Go engine */
    static const char *spatial_glue =
        "function HostFeatureGetSpatialAssociations(fid)\n"
        "  local pt=_HostFeaturePrimitive(fid); if pt=='' then return nil end\n"
        "  local arr={Type='array:SpatialAssociation'}\n"
        "  arr[1]=CreateSpatialAssociation(pt, fid..'#'..string.sub(pt,1,1), Orientation.Forward)\n"
        "  return arr\nend\n"
        "function HostGetSpatial(sid)\n"
        "  if string.sub(sid,-2)=='#S' then\n"
        "    local fid=string.sub(sid,1,-3)\n"
        "    local ext=CreateSpatialAssociation('Curve', fid..'#exterior', Orientation.Forward)\n"
        "    return CreateSurface(ext, {})\n  end\n"
        "  return nil\nend\n";
    if (luaL_dostring(L, spatial_glue) != LUA_OK) {
        fprintf(stderr, "[s101] spatial glue: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -3;
    }
    /* dispatch one feature through its rule, collect DrawingInstructions */
    static const char *driver =
        "local cps={Type='array:ContextParameter'}\n"
        "local function cp(n,t,d) table.insert(cps, PortrayalCreateContextParameter(n,t,d)) end\n"
        "cp('RadarOverlay','boolean','false')\n"
        "cp('PlainBoundaries','boolean', PLAIN_BOUNDARIES and 'true' or 'false')\n"
        "cp('SimplifiedSymbols','boolean', SIMPLIFIED_SYMBOLS and 'true' or 'false')\n"
        "cp('FourShades','boolean','true')\n"
        "cp('FullLightLines','boolean','false'); cp('IgnoreScaleMinimum','boolean','false')\n"
        "cp('ShallowWaterDangers','boolean','false'); cp('SafetyContour','real','30')\n"
        "cp('SafetyDepth','real','30'); cp('ShallowContour','real','2')\n"
        "cp('DeepContour','real','30'); cp('SafetyHeight','real','0')\n"
        "cp('PreferredLanguage','text','eng')\n"
        "PortrayalInitializeContextParameters(cps)\n"
        "local out={}\n"
        "local ctx=portrayalContext.ContextParameters\n"
        "for _,item in ipairs(portrayalContext.FeaturePortrayalItems) do\n"
        "  local feature=item.Feature\n"
        "  local fp=item:NewFeaturePortrayal()\n"
        "  local ok,err=pcall(function() require(feature.Code); _G[feature.Code](feature,fp,ctx) end)\n"
        "  if ok then out[#out+1]=table.concat(fp.DrawingInstructions, ';')\n"
        "  else out[#out+1]='ERROR:'..tostring(err) end\nend\n"
        "return table.concat(out, ' || ')\n";
    if (luaL_dostring(L, driver) != LUA_OK) {
        fprintf(stderr, "[s101] dispatch: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -4;
    }
    fprintf(stderr, "[s101] DepthArea portrayal -> %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 0;
}

/* ---- cell-driven portrayal (Host* backed by the Zig adapted features + the
 *      real Feature Catalogue via tgc_* accessors) ------------------------- */

/* Build {ref -> {UpperMultiplicity, LowerMultiplicity}} for a feature(0)/
 * complex(1)/information(2) code from the catalogue. AttributeBindings is at -1. */
static void bindings_from_cat(lua_State *L, unsigned char kind, const char *code, size_t clen) {
    size_t n = (kind == 0)   ? tgc_feature_binding_count(code, clen)
               : (kind == 1) ? tgc_complex_binding_count(code, clen)
                             : tgc_info_binding_count(code, clen);
    for (size_t j = 0; j < n; j++) {
        const char *ref = "";
        size_t rl = 0;
        int lo = 0, up = 1;
        tgc_binding(kind, code, clen, j, &ref, &rl, &lo, &up);
        lua_newtable(L);
        lua_pushinteger(L, up < 0 ? (1 << 30) : up);
        lua_setfield(L, -2, "UpperMultiplicity");
        lua_pushinteger(L, lo);
        lua_setfield(L, -2, "LowerMultiplicity");
        lua_pushlstring(L, ref, rl);
        lua_pushvalue(L, -2);    /* dup binding table */
        lua_settable(L, -4);     /* bindings[ref] = {...} */
        lua_pop(L, 1);           /* pop the leftover binding table */
    }
}
static int lp_feature_codes(lua_State *L) {
    size_t n = tgc_feature_count();
    lua_newtable(L);
    for (size_t i = 0; i < n; i++) {
        size_t len = 0;
        const char *c = tgc_feature_code(i, &len);
        lua_pushlstring(L, c, len);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
static int lp_simple_codes(lua_State *L) {
    size_t n = tgc_simple_count();
    lua_newtable(L);
    for (size_t i = 0; i < n; i++) {
        size_t len = 0;
        const char *c = tgc_simple_code(i, &len);
        lua_pushlstring(L, c, len);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
static int lp_complex_codes(lua_State *L) {
    size_t n = tgc_complex_count();
    lua_newtable(L);
    for (size_t i = 0; i < n; i++) {
        size_t len = 0;
        const char *c = tgc_complex_code(i, &len);
        lua_pushlstring(L, c, len);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
static int lp_feature_info(lua_State *L) { /* HostGetFeatureTypeInfo(code) */
    size_t clen = 0;
    const char *code = luaL_checklstring(L, 1, &clen);
    lua_newtable(L);
    lua_pushstring(L, "FeatureTypeInfo");
    lua_setfield(L, -2, "Type");
    lua_pushlstring(L, code, clen);
    lua_setfield(L, -2, "Code");
    lua_newtable(L);
    bindings_from_cat(L, 0, code, clen);
    /* Guaranteed attrs (mirror Go's withGuaranteed): some rules read these
     * without the nil-safe '!' on feature types the catalogue doesn't bind them
     * to. Binding them makes such a read return nil instead of erroring — but
     * only when the catalogue itself doesn't bind them, so we don't override a
     * real (e.g. array-valued) multiplicity. */
    push_binding_if_absent(L, "inTheWater");
    push_binding_if_absent(L, "orientationValue");
    push_binding_if_absent(L, "topmark");
    lua_setfield(L, -2, "AttributeBindings");
    return 1;
}
static int lp_info_codes(lua_State *L) { /* HostGetInformationTypeCodes() */
    size_t n = tgc_info_count();
    lua_newtable(L);
    for (size_t i = 0; i < n; i++) {
        size_t len = 0;
        const char *c = tgc_info_code(i, &len);
        lua_pushlstring(L, c, len);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
/* HostGetRoleTypeCodes / HostGetFeatureAssociationTypeCodes /
 * HostGetInformationAssociationTypeCodes: 1-based arrays of the catalogue code
 * strings. S100Scripting.lua GetTypeInfo() builds the Role/FeatureAssociation/
 * InformationAssociation Infos inline from these (no per-code Info callback). */
static int lp_role_codes(lua_State *L) {
    size_t n = tgc_role_count();
    lua_newtable(L);
    for (size_t i = 0; i < n; i++) {
        size_t len = 0;
        const char *c = tgc_role_code(i, &len);
        lua_pushlstring(L, c, len);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
static int lp_feature_assoc_codes(lua_State *L) {
    size_t n = tgc_feature_assoc_count();
    lua_newtable(L);
    for (size_t i = 0; i < n; i++) {
        size_t len = 0;
        const char *c = tgc_feature_assoc_code(i, &len);
        lua_pushlstring(L, c, len);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
static int lp_info_assoc_codes(lua_State *L) {
    size_t n = tgc_info_assoc_count();
    lua_newtable(L);
    for (size_t i = 0; i < n; i++) {
        size_t len = 0;
        const char *c = tgc_info_assoc_code(i, &len);
        lua_pushlstring(L, c, len);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
static int lp_info_info(lua_State *L) { /* HostGetInformationTypeInfo(code) */
    size_t clen = 0;
    const char *code = luaL_checklstring(L, 1, &clen);
    lua_newtable(L);
    lua_pushstring(L, "InformationTypeInfo");
    lua_setfield(L, -2, "Type");
    lua_pushlstring(L, code, clen);
    lua_setfield(L, -2, "Code");
    lua_newtable(L);
    bindings_from_cat(L, 2, code, clen);
    lua_setfield(L, -2, "AttributeBindings");
    return 1;
}
static int lp_complex_info(lua_State *L) { /* HostGetComplexAttributeTypeInfo(code) */
    size_t clen = 0;
    const char *code = luaL_checklstring(L, 1, &clen);
    lua_newtable(L);
    lua_pushstring(L, "ComplexAttributeInfo");
    lua_setfield(L, -2, "Type");
    lua_pushlstring(L, code, clen);
    lua_setfield(L, -2, "Code");
    lua_newtable(L);
    bindings_from_cat(L, 1, code, clen);
    lua_setfield(L, -2, "AttributeBindings");
    return 1;
}
static int lp_simple_info(lua_State *L) { /* HostGetSimpleAttributeTypeInfo(code) */
    size_t clen = 0;
    const char *code = luaL_checklstring(L, 1, &clen);
    size_t vl = 0;
    const char *vt = tgc_simple_valuetype(code, clen, &vl);
    lua_newtable(L);
    lua_pushstring(L, "SimpleAttributeInfo");
    lua_setfield(L, -2, "Type");
    lua_pushlstring(L, code, clen);
    lua_setfield(L, -2, "Code");
    lua_pushlstring(L, vt, vl);
    lua_setfield(L, -2, "ValueType");
    return 1;
}
static int lp_feature_ids(lua_State *L) {
    lua_newtable(L);
    size_t n = tgp_count();
    for (size_t i = 0; i < n; i++) {
        char id[24];
        snprintf(id, sizeof id, "%zu", i);
        lua_pushstring(L, id);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}
static int lp_feature_code(lua_State *L) {
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    size_t len = 0;
    const char *s = tgp_code(i, &len);
    lua_pushlstring(L, s, len);
    return 1;
}
static int lp_feature_primitive(lua_State *L) {
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    size_t len = 0;
    const char *s = tgp_primitive(i, &len);
    lua_pushlstring(L, s, len);
    return 1;
}
/* _HostFeaturePoints(fid) -> array of {x,y,z} string triples (CreatePoint takes
 * strings). Backs the #P / #M spatial glue so HostGetSpatial returns a real
 * Point/MultiPoint instead of nil (a nil Point makes the framework's GetSpatial
 * recurse forever -> "C stack overflow"). */
static int lp_feature_points(lua_State *L) {
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    size_t n = tgp_points_count(i);
    lua_newtable(L);
    for (size_t j = 0; j < n; j++) {
        double x = 0, y = 0, z = 0;
        tgp_point(i, j, &x, &y, &z);
        char b[32];
        lua_newtable(L);
        snprintf(b, sizeof b, "%.10g", x);
        lua_pushstring(L, b);
        lua_rawseti(L, -2, 1);
        snprintf(b, sizeof b, "%.10g", y);
        lua_pushstring(L, b);
        lua_rawseti(L, -2, 2);
        snprintf(b, sizeof b, "%.10g", z);
        lua_pushstring(L, b);
        lua_rawseti(L, -2, 3);
        lua_rawseti(L, -2, (lua_Integer)(j + 1));
    }
    return 1;
}
/* HostSpatialGetAssociatedFeatureIDs(spatialID): for a POINT spatial ("<fid>#P"),
 * return the feature IDs co-located with <fid> so LightFlareAndDescription's
 * co-located-light rule (the 45-degree flare — an S-101 portrayal DEFAULT; S-65
 * does not derive flareBearing for this) can run. Line/area spatials (#S/#M/#exterior)
 * return an empty list, so the curve/area rules that also read AssociatedFeatures are
 * unaffected. IDs are the decimal feature indices lp_feature_ids/featureCache use. */
static int lp_spatial_assoc_features(lua_State *L) {
    size_t slen = 0;
    const char *sid = luaL_checklstring(L, 1, &slen);
    lua_newtable(L);
    if (slen < 3 || sid[slen - 2] != '#' || sid[slen - 1] != 'P') return 1; /* points only */
    size_t i = (size_t)atol(sid); /* the "<fid>" prefix */
    size_t buf[64];
    size_t n = tgp_colocated(i, buf, sizeof buf / sizeof buf[0]);
    for (size_t k = 0; k < n; k++) {
        char id[24];
        snprintf(id, sizeof id, "%zu", buf[k]);
        lua_pushstring(L, id);
        lua_rawseti(L, -2, (lua_Integer)(k + 1));
    }
    return 1;
}
/* HostFeatureGetAssociatedFeatureIDs(id, assocCode, roleCode): the feature IDs this
 * feature's S-57 FFPT pointers reference for association `assocCode`, filtered by role
 * (RIND-derived). S-57 FFPT only models the structure<->equipment relationship and carries
 * no association code, so tgp_assoc_features answers StructureEquipment only and returns
 * empty for any other code — notably 'TextAssociation', which S-57 can't represent.
 * (Answering every code from FFPT returned wrong-class features; the framework then read
 * the TextPlacement-only attribute textType on a beacon -> "Invalid attribute code" ->
 * QUESMRK1.) roleCode (nil = any) selects the pointer direction. IDs are decimal adapted
 * indices. */
static int lp_feature_assoc_features(lua_State *L) {
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    size_t alen = 0, rlen = 0;
    const char *assoc = lua_isnoneornil(L, 2) ? "" : luaL_checklstring(L, 2, &alen);
    const char *role = lua_isnoneornil(L, 3) ? "" : luaL_checklstring(L, 3, &rlen);
    lua_newtable(L);
    size_t buf[64];
    size_t n = tgp_assoc_features(i, assoc, alen, role, rlen, buf, sizeof buf / sizeof buf[0]);
    for (size_t k = 0; k < n; k++) {
        char id[24];
        snprintf(id, sizeof id, "%zu", buf[k]);
        lua_pushstring(L, id);
        lua_rawseti(L, -2, (lua_Integer)(k + 1));
    }
    return 1;
}
static int lp_feature_simple_attr(lua_State *L) { /* (id, path, code) -> {value(s)} */
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    const char *path = lua_tostring(L, 2); /* the framework attributePath; "" = the feature root */
    const char *code = luaL_checkstring(L, 3);
    size_t len = 0;
    /* Resolve the FULL attributePath through the synthesized tree: an empty path is
     * the feature root (its own simple attributes), a non-empty path
     * ("featureName:1", "sectorCharacteristics:1;lightSector:1", …) the addressed
     * nested node. tgp_simple returns the raw value; the split below turns an S-57
     * list value into the array the framework expects. */
    const char *v = tgp_simple(i, path ? path : "", path ? strlen(path) : 0,
                               code, strlen(code), &len);
    lua_newtable(L);
    if (v) {
        /* enumeration / integer attributes are S-57 comma-separated lists (e.g.
         * COLOUR "1,3", NATSUR "4,6"); the framework expects ONE array element per
         * value, so a rule like hasValue(COLOUR, 3) can match. text / real / date
         * values are single-valued and served verbatim. Mirrors Go splitValue
         * (s101/complex.go:258). */
        size_t vtl = 0;
        const char *vt = tgc_simple_valuetype(code, strlen(code), &vtl);
        int is_list = vt != NULL &&
            ((vtl == 11 && memcmp(vt, "enumeration", 11) == 0) ||
             (vtl == 7 && memcmp(vt, "integer", 7) == 0));
        if (is_list) {
            int idx = 1;
            const char *start = v;
            const char *vend = v + len;
            for (const char *p = v; p <= vend; p++) {
                if (p == vend || *p == ',') {
                    const char *s = start, *e = p; /* trim surrounding blanks */
                    while (s < e && (*s == ' ' || *s == '\t')) s++;
                    while (e > s && (e[-1] == ' ' || e[-1] == '\t')) e--;
                    if (e > s) {
                        lua_pushlstring(L, s, (size_t)(e - s));
                        lua_rawseti(L, -2, idx++);
                    }
                    start = p + 1;
                }
            }
        } else {
            lua_pushlstring(L, v, len);
            lua_rawseti(L, -2, 1);
        }
    }
    return 1;
}
static int lp_feature_complex_count(lua_State *L) { /* (id, path, code) -> count */
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    const char *path = lua_tostring(L, 2); /* "" = the feature root */
    const char *code = luaL_checkstring(L, 3);
    size_t c = tgp_complex_count(i, path ? path : "", path ? strlen(path) : 0,
                                 code, strlen(code));
    lua_pushinteger(L, (lua_Integer)c);
    return 1;
}
static int lp_store(lua_State *L) { /* tg_store(index, instr) */
    size_t i = (size_t)luaL_checkinteger(L, 1);
    size_t len = 0;
    const char *s = lua_tolstring(L, 2, &len);
    tgp_emit(i, s ? s : "", len);
    return 0;
}

/* Run the S-101 rules over the adapted cell features (tgp_*), storing each
 * feature's instruction stream via tgp_emit. `ctx` carries the S-101 context
 * parameters for the pass (see tg_portray_ctx): the display-variant axes
 * (PlainBoundaries §8.6.1 / SimplifiedSymbols §11.2.2) plus the mariner
 * depth/light/danger parameters. NULL reproduces the fixed bake context
 * unchanged. Returns 0 on success. */
int tg_portray_run(const char *dir, size_t dir_len, const tg_portray_ctx *ctx) {
    char dbuf[4096];
    if (dir_len >= sizeof dbuf) return -1;
    memcpy(dbuf, dir, dir_len);
    dbuf[dir_len] = 0;

    lua_State *L = luaL_newstate();
    if (!L) return -100;
    luaL_openlibs(L);
    /* Embedded rules are always available (searcher fallback). An explicit rules
     * dir (dir_len > 0) is added to package.path so it takes precedence; with no
     * dir, the rules load straight from the binary — no on-disk catalogue. */
    install_embedded_searcher(L);
    if (dir_len > 0) {
        char buf[8192];
        snprintf(buf, sizeof buf, "package.path = '%s/?.lua;' .. package.path", dbuf);
        if (luaL_dostring(L, buf) != LUA_OK) {
            fprintf(stderr, "[s101] package.path: %s\n", lua_tostring(L, -1));
            lua_close(L);
            return -1;
        }
    }

    lua_register(L, "HostGetFeatureTypeCodes", lp_feature_codes);
    lua_register(L, "HostGetSimpleAttributeTypeCodes", lp_simple_codes);
    lua_register(L, "HostGetFeatureTypeInfo", lp_feature_info);
    lua_register(L, "HostGetSimpleAttributeTypeInfo", lp_simple_info);
    lua_register(L, "HostGetFeatureIDs", lp_feature_ids);
    lua_register(L, "HostFeatureGetCode", lp_feature_code);
    lua_register(L, "_HostFeaturePrimitive", lp_feature_primitive);
    lua_register(L, "_HostFeaturePoints", lp_feature_points);
    lua_register(L, "HostFeatureGetSimpleAttribute", lp_feature_simple_attr);
    lua_register(L, "HostFeatureGetComplexAttributeCount", lp_feature_complex_count);
    lua_register(L, "HostPortrayalEmit", l_true);
    lua_register(L, "HostDebuggerEntry", l_debug_entry);
    lua_register(L, "tg_store", lp_store);
    lua_register(L, "HostGetComplexAttributeTypeCodes", lp_complex_codes);
    lua_register(L, "HostGetComplexAttributeTypeInfo", lp_complex_info);
    /* information types (SpatialQuality etc., served from the catalogue); the
     * spatial-quality association functions themselves are Lua glue below. */
    lua_register(L, "HostGetInformationTypeCodes", lp_info_codes);
    lua_register(L, "HostGetInformationTypeInfo", lp_info_info);
    /* role / association type-code lists (from the embedded Feature Catalogue) */
    lua_register(L, "HostGetRoleTypeCodes", lp_role_codes);
    lua_register(L, "HostGetInformationAssociationTypeCodes", lp_info_assoc_codes);
    lua_register(L, "HostGetFeatureAssociationTypeCodes", lp_feature_assoc_codes);
    lua_register(L, "HostFeatureGetAssociatedFeatureIDs", lp_feature_assoc_features);
    /* feature->information: S-57 has no such record pointer (info rides on
     * attributes / the synthesized `information` complex), so there are no IDs to
     * surface — left empty. */
    lua_register(L, "HostFeatureGetAssociatedInformationIDs", l_empty_table);
    lua_register(L, "HostSpatialGetAssociatedFeatureIDs", lp_spatial_assoc_features);
    lua_register(L, "HostSpatialGetAssociatedInformationIDs", l_empty_table);
    lua_register(L, "HostInformationTypeGetCode", l_empty_string);
    lua_register(L, "HostInformationTypeGetSimpleAttribute", l_empty_table);
    lua_register(L, "HostInformationTypeGetComplexAttributeCount", l_zero);

    if (luaL_dostring(L,
            "require 'S100Scripting'; require 'PortrayalModel'; "
            "require 'PortrayalAPI'; require 'Default'; require 'main'") != LUA_OK) {
        fprintf(stderr, "[s101] framework load: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -2;
    }
    // Spatial glue (installed after the framework loads so it can use the
    // framework constructors). Each feature is one association of its primitive
    // type; HostGetSpatial resolves it. A `#P` point MUST resolve to a real Point
    // (never nil): the framework's GetSpatial does `self.Spatial = sa.Spatial`
    // then re-reads `self.Spatial`, and a nil leaves the field absent so the
    // re-read re-enters GetSpatial forever (the OBSTRN/WRECKS "C stack overflow").
    // Line/area boundary geometry isn't read here — scene attaches it directly.
    static const char *glue =
        "function HostFeatureGetSpatialAssociations(fid)\n"
        "  local pt=_HostFeaturePrimitive(fid); if pt=='' then return nil end\n"
        "  local arr={Type='array:SpatialAssociation'}\n"
        "  arr[1]=CreateSpatialAssociation(pt, fid..'#'..string.sub(pt,1,1), Orientation.Forward)\n"
        "  return arr\nend\n"
        "function HostGetSpatial(sid)\n"
        "  local suf=string.sub(sid,-2)\n"
        "  if suf=='#S' then\n"
        "    local fid=string.sub(sid,1,-3)\n"
        "    local ext=CreateSpatialAssociation('Curve', fid..'#exterior', Orientation.Forward)\n"
        "    return CreateSurface(ext, {})\n  end\n"
        "  if suf=='#M' then\n"
        "    local fid=string.sub(sid,1,-3)\n"
        "    local pts=_HostFeaturePoints(fid)\n"
        "    local sp={Type='array:Spatial'}\n"
        "    for _,p in ipairs(pts) do sp[#sp+1]=CreatePoint(p[1],p[2],p[3]) end\n"
        "    return CreateMultiPoint(sp)\n  end\n"
        "  if suf=='#P' then\n"
        "    local fid=string.sub(sid,1,-3)\n"
        "    local pts=_HostFeaturePoints(fid)\n"
        "    if pts[1] then return CreatePoint(pts[1][1],pts[1][2],pts[1][3]) end\n"
        "    return CreatePoint('0','0',nil)\n  end\n"
        "  return nil\nend\n"
        /* Spatial Quality on geometry (S-65 §2.2.3, Gap D): S-57 QUAPOS lives on the
         * spatial records; S-101 models it as a SpatialQuality information type
         * associated with each spatial. The adapter already aggregates the feature's
         * edge/node QUAPOS to a remapped qualityOfHorizontalMeasurement on the
         * feature root (s101_adapt s65RemapQuapos), so a feature that carries it
         * exposes ONE SpatialQuality association on every spatial of its geometry —
         * the same per-feature granularity as the scene force_dash approximation.
         * This lights the real rule branches: QUAPNT02's LOWACC01 mark, QUALIN02's
         * LOWACC21 coastline, DEPCNT03/DEPARE03's dashed low-accuracy contours. */
        "function HostSpatialGetAssociatedInformationIDs(sid, assoc, role)\n"
        "  if assoc~='SpatialAssociation' then return nil end\n"
        "  local fid=string.match(sid,'^(.-)#')\n"
        "  if not fid then return nil end\n"
        "  local v=HostFeatureGetSimpleAttribute(fid,'','qualityOfHorizontalMeasurement')\n"
        "  if v and v[1] then return { fid..'#SQ' } end\n"
        "  return nil\nend\n"
        "function HostInformationTypeGetCode(iid)\n"
        "  if string.sub(iid,-3)=='#SQ' then return 'SpatialQuality' end\n"
        "  return ''\nend\n"
        "function HostInformationTypeGetSimpleAttribute(iid, path, code)\n"
        "  if code=='qualityOfHorizontalMeasurement' then\n"
        "    local fid=string.match(iid,'^(.-)#SQ$')\n"
        "    if fid then return HostFeatureGetSimpleAttribute(fid,'',code) end\n"
        "  end\n"
        "  return {}\nend\n";
    if (luaL_dostring(L, glue) != LUA_OK) {
        fprintf(stderr, "[s101] glue: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -3;
    }
    static const char *driver =
        "local cps={Type='array:ContextParameter'}\n"
        "local function cp(n,t,d) table.insert(cps, PortrayalCreateContextParameter(n,t,d)) end\n"
        "local function b(v) return v and 'true' or 'false' end\n"
        /* Context values come from the tg_portray_ctx globals (tg_set_ctx_globals);
         * reals arrive pre-formatted as strings so the default pass hands the rules
         * the exact literals the old static driver did. */
        "cp('RadarOverlay','boolean', b(RADAR_OVERLAY))\n"
        "cp('PlainBoundaries','boolean', b(PLAIN_BOUNDARIES))\n"
        "cp('SimplifiedSymbols','boolean', b(SIMPLIFIED_SYMBOLS))\n"
        "cp('FourShades','boolean', b(FOUR_SHADES))\n"
        "cp('FullLightLines','boolean', b(FULL_LIGHT_LINES)); cp('IgnoreScaleMinimum','boolean', b(IGNORE_SCALE_MINIMUM))\n"
        "cp('ShallowWaterDangers','boolean', b(SHALLOW_WATER_DANGERS)); cp('SafetyContour','real', SAFETY_CONTOUR)\n"
        "cp('SafetyDepth','real', SAFETY_DEPTH); cp('ShallowContour','real', SHALLOW_CONTOUR)\n"
        "cp('DeepContour','real', DEEP_CONTOUR); cp('SafetyHeight','real', SAFETY_HEIGHT)\n"
        "cp('PreferredLanguage','text','eng')\n"
        "PortrayalInitializeContextParameters(cps)\n"
        // Drive portrayal through the reference S-100 Part 9a entry point exactly as
        // the catalogue intends. HostPortrayalEmit is the framework's per-feature
        // emit callback (9A-14.2.1): route each feature's joined instructions into our
        // tgp_emit sink, keyed by FeatureReference (== feature.ID == our feature index),
        // and return true to continue. PortrayalMain() then runs the full
        // ProcessFeaturePortrayalItem wrapper per feature — ProcessFixedAndPeriodicDates,
        // ScaleMinimum/ScaleMaximum, the rule, PortrayFeatureName fallback,
        // ProcessNauticalInformation (info/picture-available indicators),
        // AddDateDependentSymbol, deferred TextPlacement, and Default()-on-error — that
        // our old hand-rolled loop skipped.
        "function HostPortrayalEmit(ref, instr, observed)\n"
        "  tg_store(tonumber(ref), instr or '')\n"
        "  return true\nend\n"
        "PortrayalMain()\n";
    lua_pushboolean(L, g_portray_quiet);
    lua_setglobal(L, "QUIET");
    /* The pass's S-101 context parameters, read by the driver's cp() lines.
     * NULL => the fixed bake context (see tg_default_ctx). */
    tg_set_ctx_globals(L, ctx ? ctx : &tg_default_ctx);
    int rc = 0;
    if (luaL_dostring(L, driver) != LUA_OK) {
        fprintf(stderr, "[s101] dispatch: %s\n", lua_tostring(L, -1));
        rc = -4;
    }
    lua_close(L);
    return rc;
}

/* Compatibility check: with `dir` as the S-101 Rules directory, set package.path
 * and load the framework (S100Scripting/PortrayalModel/PortrayalAPI/Default/
 * main) in embedded Lua 5.4. Returns 0 on success, negative on error (message to
 * stderr). This exercises the most complex framework files — strong evidence of
 * whether the 5.1-authored rules run under 5.4. */
int tile57_diag_check_rules(const char *dir) {
    lua_State *L = luaL_newstate();
    if (!L) return -100;
    luaL_openlibs(L);
    install_embedded_searcher(L); /* embedded rules fall back when `dir` has none */
    char buf[8192];
    snprintf(buf, sizeof buf, "package.path = '%s/?.lua;' .. package.path", dir);
    int rc = 0;
    if (luaL_dostring(L, buf) != LUA_OK) {
        fprintf(stderr, "[s101] package.path: %s\n", lua_tostring(L, -1));
        rc = -1;
    } else if (luaL_dostring(L,
                   "require 'S100Scripting'; require 'PortrayalModel'; "
                   "require 'PortrayalAPI'; require 'Default'; require 'main'") != LUA_OK) {
        fprintf(stderr, "[s101] framework load: %s\n", lua_tostring(L, -1));
        rc = -2;
    } else {
        fprintf(stderr, "[s101] framework loaded OK in %s\n", LUA_VERSION);
    }
    lua_close(L);
    return rc;
}
