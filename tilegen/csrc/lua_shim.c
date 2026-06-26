/* lua_shim.c — tiny C bridge to the embedded Lua 5.4, compiled into
 * libtilegen.a. Lua's convenience macros (luaL_dostring, lua_pcall, ...) are
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
#include <string.h>

/* Run a trivial Lua chunk and return its integer result, or a negative error.
 * Used to verify the embedded interpreter end to end. */
long tg_lua_selftest(void) {
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
const char *tg_lua_version(void) { return LUA_VERSION; }

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
int tg_lua_run_framework(const char *dir) {
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
int tg_lua_portray_demo(const char *dir) {
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

/* Compatibility check: with `dir` as the S-101 Rules directory, set package.path
 * and load the framework (S100Scripting/PortrayalModel/PortrayalAPI/Default/
 * main) in embedded Lua 5.4. Returns 0 on success, negative on error (message to
 * stderr). This exercises the most complex framework files — strong evidence of
 * whether the 5.1-authored rules run under 5.4. */
int tg_lua_check_rules(const char *dir) {
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
