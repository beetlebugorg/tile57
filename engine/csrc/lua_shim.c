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
extern const char *tgp_attr(size_t i, const char *name, size_t nlen, size_t *len);
extern size_t tgp_complex_count(size_t i, const char *name, size_t nlen);
extern const char *tgp_complex_attr(size_t i, const char *path, size_t plen,
                                    const char *code, size_t clen, size_t *len);
extern void tgp_emit(size_t i, const char *instr, size_t len);
extern size_t tgp_points_count(size_t i);
extern void tgp_point(size_t i, size_t j, double *x, double *y, double *z);

/* Catalogue accessors implemented in Zig (catalogue.zig). */
extern size_t tgc_feature_count(void);
extern const char *tgc_feature_code(size_t i, size_t *len);
extern size_t tgc_simple_count(void);
extern const char *tgc_simple_code(size_t i, size_t *len);
extern size_t tgc_complex_count(void);
extern const char *tgc_complex_code(size_t i, size_t *len);
extern size_t tgc_feature_binding_count(const char *code, size_t code_len);
extern size_t tgc_complex_binding_count(const char *code, size_t code_len);
extern void tgc_binding(unsigned char kind, const char *code, size_t code_len, size_t j,
                        const char **ref, size_t *ref_len, int *lower, int *upper);
extern const char *tgc_simple_valuetype(const char *code, size_t code_len, size_t *len);

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
 * 0.16's env access is behind Io; reading it here keeps tile57_source_open simple.)
 * Used only as a fallback when tile57_source_open's rules_dir argument is NULL. */
const char *tg_env_rules(void) { return getenv("TILE57_S101_RULES"); }

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

/* Prove the framework EXECUTES in embedded Lua 5.4: with stub Host callbacks and
 * an empty feature set, initialize the portrayal context and report the
 * FeaturePortrayalItems count (0). Returns 0 on success, negative on error. */
int tile57_diag_run_framework(const char *dir) {
    lua_State *L = luaL_newstate();
    if (!L) return -100;
    luaL_openlibs(L);
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
    lua_register(L, "HostDebuggerEntry", l_noop);
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
        "cp('RadarOverlay','boolean','false'); cp('PlainBoundaries','boolean','false')\n"
        "cp('SimplifiedSymbols','boolean','false'); cp('FourShades','boolean','true')\n"
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
 * complex(1) code from the catalogue. The AttributeBindings table is at -1. */
static void bindings_from_cat(lua_State *L, unsigned char kind, const char *code, size_t clen) {
    size_t n = (kind == 0) ? tgc_feature_binding_count(code, clen)
                           : tgc_complex_binding_count(code, clen);
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
static int lp_feature_simple_attr(lua_State *L) { /* (id, path, code) -> {value} */
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    const char *path = lua_tostring(L, 2);
    const char *code = luaL_checkstring(L, 3);
    size_t len = 0;
    const char *v = NULL;
    /* A simple attribute inside a complex instance carries a non-empty
     * attributePath whose leading segment names the complex (e.g. "featureName:1",
     * "zoneOfConfidence:1"); serve it from the synthesized complex-attribute store.
     * Falls back to the flat attr list when there is no such complex sub-attr. */
    if (path && *path) {
        v = tgp_complex_attr(i, path, strlen(path), code, strlen(code), &len);
    }
    if (!v) {
        v = tgp_attr(i, code, strlen(code), &len);
    }
    lua_newtable(L);
    if (v) {
        lua_pushlstring(L, v, len);
        lua_rawseti(L, -2, 1);
    }
    return 1;
}
static int lp_feature_complex_count(lua_State *L) { /* (id, path, code) -> count */
    size_t i = (size_t)atol(luaL_checkstring(L, 1));
    const char *code = luaL_checkstring(L, 3);
    size_t c = tgp_complex_count(i, code, strlen(code));
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
 * feature's instruction stream via tgp_emit. Returns 0 on success. */
int tg_portray_run(const char *dir, size_t dir_len) {
    char dbuf[4096];
    if (dir_len >= sizeof dbuf) return -1;
    memcpy(dbuf, dir, dir_len);
    dbuf[dir_len] = 0;

    lua_State *L = luaL_newstate();
    if (!L) return -100;
    luaL_openlibs(L);
    char buf[8192];
    snprintf(buf, sizeof buf, "package.path = '%s/?.lua;' .. package.path", dbuf);
    if (luaL_dostring(L, buf) != LUA_OK) {
        fprintf(stderr, "[s101] package.path: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -1;
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
    lua_register(L, "HostDebuggerEntry", l_noop);
    lua_register(L, "tg_store", lp_store);
    lua_register(L, "HostGetComplexAttributeTypeCodes", lp_complex_codes);
    lua_register(L, "HostGetComplexAttributeTypeInfo", lp_complex_info);
    /* empty catalogue tables */
    lua_register(L, "HostGetInformationTypeCodes", l_empty_table);
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
    // Spatial glue (installed after the framework loads so it can use the
    // framework constructors). Each feature is one association of its primitive
    // type; HostGetSpatial resolves it. A `#P` point MUST resolve to a real Point
    // (never nil): the framework's GetSpatial does `self.Spatial = sa.Spatial`
    // then re-reads `self.Spatial`, and a nil leaves the field absent so the
    // re-read re-enters GetSpatial forever (the OBSTRN/WRECKS "C stack overflow").
    // Line/area boundary geometry isn't read here — s57_mvt attaches it directly.
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
        "  return nil\nend\n";
    if (luaL_dostring(L, glue) != LUA_OK) {
        fprintf(stderr, "[s101] glue: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return -3;
    }
    static const char *driver =
        "local cps={Type='array:ContextParameter'}\n"
        "local function cp(n,t,d) table.insert(cps, PortrayalCreateContextParameter(n,t,d)) end\n"
        "cp('RadarOverlay','boolean','false'); cp('PlainBoundaries','boolean','false')\n"
        "cp('SimplifiedSymbols','boolean','false'); cp('FourShades','boolean','true')\n"
        "cp('FullLightLines','boolean','false'); cp('IgnoreScaleMinimum','boolean','false')\n"
        "cp('ShallowWaterDangers','boolean','false'); cp('SafetyContour','real','30')\n"
        "cp('SafetyDepth','real','30'); cp('ShallowContour','real','2')\n"
        "cp('DeepContour','real','30'); cp('SafetyHeight','real','0')\n"
        "cp('PreferredLanguage','text','eng')\n"
        "PortrayalInitializeContextParameters(cps)\n"
        "local ctx=portrayalContext.ContextParameters\n"
        "local nok,nerr,nskip,ntext,errs=0,0,0,0,{}\n"
        "for _,item in ipairs(portrayalContext.FeaturePortrayalItems) do\n"
        "  local feature=item.Feature\n"
        "  local fp=item:NewFeaturePortrayal()\n"
        "  local ok,err=pcall(function() require(feature.Code); _G[feature.Code](feature,fp,ctx) end)\n"
        "  local instr\n"
        "  if ok then nok=nok+1; instr=table.concat(fp.DrawingInstructions, ';')\n"
        // A feature whose own class has no rule file is NOT an error: the catalogue
        // simply doesn't portray it (e.g. SweptArea/SWPARE — an IHO gap). Leave
        // instr nil so it falls back to classify(), and tally it apart from real
        // rule errors. Matches the Go reference, which suppresses these silently.
        // The match is on feature.Code so a *different* missing require inside a
        // rule (a real bug) still counts as an error.
        "  elseif tostring(err):find(\"module '\"..feature.Code..\"' not found\", 1, true) then nskip=nskip+1\n"
        "  else nerr=nerr+1; instr='ERROR:'..tostring(err)\n"
        // PrimitiveType is a PortrayalAPI enum *table*; print its .Name (Point/
        // Curve/Surface) rather than the useless "table: 0x..." address.
        "    errs[feature.Code]=(errs[feature.Code] or (tostring(err)..' [prim='..(feature.PrimitiveType and feature.PrimitiveType.Name or '?')..']')) end\n"
        "  if instr and instr:find('TextInstruction') then ntext=ntext+1 end\n"
        "  tg_store(tonumber(feature.ID), instr)\nend\n"
        "io.stderr:write('[s101] portrayed '..nok..' ok, '..nerr..' errors, '..nskip..' unportrayed, '..ntext..' with text\\n')\n"
        "for code,e in pairs(errs) do io.stderr:write('  '..code..': '..e..'\\n') end\n";
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
