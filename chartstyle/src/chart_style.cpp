#include "chartstyle/chart_style.hpp"

#include <nlohmann/json.hpp>

#include <string>
#include <vector>

namespace chartstyle {
namespace {

using json = nlohmann::json;

constexpr double M_TO_FT = 3.280839895;
constexpr const char *FALLBACK = "#ff00ff";

json get(const char *prop) { return json::array({"get", prop}); }
json coalesce(json expr, json fallback) {
    return json::array({"coalesce", std::move(expr), std::move(fallback)});
}

// SEABED01 (S-52 §13.2.15): DRVAL1/DRVAL2 vs the mariner's shallow/safety/deep
// contours -> a depth colour token. Deepest band first (the spec cascade's last
// match wins -> first match in a `case`). `>= X && > X` on both bounds per spec.
json seabedTokenExpr(const MarinerSettings &m) {
    const json d1 = coalesce(get("drval1"), -1);
    const json d2 = coalesce(get("drval2"), 0);
    auto band = [&](double x) {
        return json::array({"all", json::array({">=", d1, x}), json::array({">", d2, x})});
    };
    if (!m.fourShadeWater) {
        return json::array({"case", band(m.safetyContour), "DEPDW", band(0.0), "DEPVS", "DEPIT"});
    }
    return json::array({"case", band(m.deepContour), "DEPDW", band(m.safetyContour), "DEPMD",
                        band(m.shallowContour), "DEPMS", band(0.0), "DEPVS", "DEPIT"});
}

// Resolve a colour-token-valued expression to an RGB for the active scheme.
json colorMatch(const json &tokenExpr, const json &palette, const char *fallback = FALLBACK) {
    json m = json::array({"match", tokenExpr});
    for (auto it = palette.begin(); it != palette.end(); ++it) {
        m.push_back(it.key());
        m.push_back(it.value());
    }
    m.push_back(fallback);
    return m;
}

// A single resolved colour token for the scheme (concrete value, not an expression).
std::string token(const json &palette, const char *name, const char *fallback) {
    auto it = palette.find(name);
    return (it != palette.end() && it->is_string()) ? it->get<std::string>() : std::string(fallback);
}

// line-color for the S-52 line layers: the feature's baked colour token resolved
// against the active scheme's palette.
json lineColor(const json &palette) { return colorMatch(coalesce(get("color_token"), ""), palette); }

// Text ink. Day uses the per-feature S-52 ink; dusk/night use a bright neutral so
// labels stay legible on the dark palette (matches the Go client).
json textColor(Scheme s, const json &palette) {
    if (s == Scheme::Day) return colorMatch(coalesce(get("color_token"), ""), palette, "#000000");
    return json(s == Scheme::Night ? "#aab7bf" : "#dde7ec");
}
json textHaloColor(Scheme s) {
    return json(s == Scheme::Day ? "rgba(255,255,255,0.9)" : "rgba(0,0,0,0.85)");
}
// Contour (depth) labels: CHGRD by day, bright neutral at dusk/night.
json contourLabelColor(Scheme s, const json &palette) {
    if (s == Scheme::Day) return json(token(palette, "CHGRD", "#5a5a44"));
    return json(s == Scheme::Night ? "#aab7bf" : "#dde7ec");
}

// Fill colour for the `areas` layer: depth areas (carry drval1) shade live via
// SEABED01; everything else uses its baked colour token.
json areasFillColor(const json &palette, const MarinerSettings &m) {
    return json::array({"case", json::array({"has", "drval1"}),
                        colorMatch(seabedTokenExpr(m), palette),
                        colorMatch(coalesce(get("color_token"), ""), palette)});
}

// SNDFRM04 (S-52 §13.2.16): a sounding <= the live safety depth uses the bold
// SOUNDS glyphs, else the faint SOUNDG glyphs. (Imperial mode needs client-side
// glyph synthesis — deferred; metres reuses the baked sym_s/sym_g.)
json soundingsIconImage(const MarinerSettings &m) {
    const json depthLE = json::array({"<=", coalesce(get("depth"), 0), m.safetyDepth});
    return json::array({"case", json::array({"has", "sym_s"}),
                        json::array({"case", depthLE, get("sym_s"), get("sym_g")}),
                        get("symbol_names")});
}

// OBSTRN06/WRECKS05 (S-52 §13.2.6/§13.2.20): a danger symbol deeper than the live
// safety contour swaps to the less-prominent DANGER02 (sym_deep). pivot_center
// draws the centred "ctr:" image variant.
json pointSymbolImage(const MarinerSettings &m) {
    const json name =
        json::array({"case",
                     json::array({"all", json::array({"has", "sym_deep"}),
                                  json::array({">", coalesce(get("danger_depth"), 0), m.safetyContour})}),
                     get("sym_deep"), get("symbol_name")});
    return json::array({"case", json::array({"==", coalesce(get("pivot_center"), 0), 1}),
                        json::array({"concat", "ctr:", name}), name});
}

// SAFCON01 (S-52 §13.2.13): the depth-contour value label, in whole metres or whole
// feet per the mariner's depth unit.
json contourLabelField(const MarinerSettings &m) {
    const json v = m.depthUnit == DepthUnit::Feet
                       ? json::array({"round", json::array({"*", get("valdco"), M_TO_FT})})
                       : json::array({"round", get("valdco")});
    return json::array({"case", json::array({"has", "valdco"}), json::array({"to-string", v}), ""});
}

// Display category (S-52 §10.3.4), client-side + multi-select: each feature is
// baked with its category rank `cat` (0 base, 1 standard, 2 other); the mariner
// independently toggles each. Folds in the M_QUAL data-quality overlay (its own
// toggle, independent of "Other"). Mirrors the Go client's categoryFilter.
json categoryFilter(const MarinerSettings &m) {
    json en = json::array();
    if (m.displayBase) en.push_back(0);
    if (m.displayStandard) en.push_back(1);
    if (m.displayOther) en.push_back(2);
    // Isolated dangers (ISODGR01): Base normally, Standard when "isolated dangers in
    // shallow water" is on. Every other feature uses its baked cat (default standard).
    const int isoCat = m.showIsolatedDangersShallow ? 1 : 0;
    const json cat = json::array({"case", json::array({"==", get("symbol_name"), "ISODGR01"}),
                                  isoCat, coalesce(get("cat"), 1)});
    const json inCat = json::array({"in", cat, json::array({"literal", en})});
    const json isQual = json::array({"==", get("class"), "M_QUAL"});
    if (m.dataQuality)
        return json::array({"any", isQual, json::array({"all", inCat, json::array({"!", isQual})})});
    return json::array({"all", inCat, json::array({"!", isQual})});
}

// S-52 §14.5 text-group selection: each text feature carries its `tgrp` tag; the
// mariner toggles which groups show. Important text (11) is always on (safety-
// critical clearances/bearings). Names = 21/26/29, light descriptions = 23, Other =
// everything else. Returns false (hide all) if every group is disabled. Mirrors the
// Go client's textGroupFilter.
json textGroupFilter(const MarinerSettings &m) {
    const json g = coalesce(get("tgrp"), -1);
    const json named = json::array({"match", g, json::array({21, 26, 29}), true, false});
    json clauses = json::array();
    clauses.push_back(json::array({"==", g, 11})); // important — always on
    if (m.textNames) clauses.push_back(named);
    if (m.showLightDescriptions) clauses.push_back(json::array({"==", g, 23}));
    if (m.textOther)
        clauses.push_back(json::array({"all", json::array({"!=", g, 11}), json::array({"!=", g, 23}),
                                       json::array({"match", g, json::array({21, 26, 29}), false, true})}));
    json any = json::array({"any"}); // important text keeps this non-empty
    for (auto &c : clauses) any.push_back(c);
    return any;
}

// AND extra clauses into a layer's existing filter (clauses first, base last).
void andInto(json &layer, const std::vector<json> &clauses) {
    json all = json::array({"all"});
    for (const auto &c : clauses) all.push_back(c);
    if (layer.contains("filter")) all.push_back(layer["filter"]);
    layer["filter"] = std::move(all);
}

bool isId(const json &layer, std::initializer_list<const char *> ids) {
    if (!layer.contains("id") || !layer["id"].is_string()) return false;
    const std::string id = layer["id"];
    for (const char *want : ids)
        if (id == want) return true;
    return false;
}

} // namespace

std::string buildStyle(const std::string &templateJson, const MarinerSettings &m,
                       const std::string &colortablesJson) {
    json style, cts;
    try {
        style = json::parse(templateJson);
        cts = colortablesJson.empty() ? json::object() : json::parse(colortablesJson);
    } catch (const std::exception &) {
        return templateJson;
    }
    if (!style.contains("layers") || !style["layers"].is_array()) return templateJson;

    const char *schemeKey =
        m.scheme == Scheme::Night ? "night" : (m.scheme == Scheme::Dusk ? "dusk" : "day");
    const json palette = cts.contains(schemeKey) ? cts[schemeKey] : json::object();

    for (json &L : style["layers"]) {
        // -- colour scheme (Day/Dusk/Night): regenerate every palette-driven colour
        // from the active scheme. Only when a palette is available, else keep the
        // template's baked colours (avoids an all-magenta fallback). --
        if (!palette.empty()) {
            const bool isContourLabel = isId(L, {"contour-labels-lines", "contour-labels-lines_scamin"});
            if (isId(L, {"background"}))
                L["paint"]["background-color"] = token(palette, "DEPDW", "#c9edff");
            if (isId(L, {"fill-areas", "fill-areas_scamin"}))
                L["paint"]["fill-color"] = areasFillColor(palette, m);
            if (L.contains("paint") && L["paint"].contains("line-color"))
                L["paint"]["line-color"] = lineColor(palette);
            if (L.contains("paint") && L["paint"].contains("text-color"))
                L["paint"]["text-color"] = isContourLabel ? contourLabelColor(m.scheme, palette)
                                                          : textColor(m.scheme, palette);
            if (L.contains("paint") && L["paint"].contains("text-halo-color"))
                L["paint"]["text-halo-color"] = textHaloColor(m.scheme);
        }
        if (isId(L, {"soundings"}))
            L["layout"]["icon-image"] = soundingsIconImage(m);
        if (isId(L, {"point_symbols", "point_symbols_scamin", "point_symbols-north",
                     "point_symbols_scamin-north"}))
            L["layout"]["icon-image"] = pointSymbolImage(m);
        if (isId(L, {"contour-labels-lines", "contour-labels-lines_scamin"}))
            L["layout"]["text-field"] = contourLabelField(m);

        // Client-side display portrayal, AND-ed onto each chart-source layer's own
        // filter: display category (+ data-quality overlay), then the info-callout
        // ("flyout") toggle. The boundary/point-style/sector/text-group/date axes
        // join here once the engine bakes their per-feature tags.
        if (L.value("source", std::string()) == "chart") {
            std::vector<json> clauses;
            clauses.push_back(categoryFilter(m));
            if (!m.showInformCallouts) // INFORM01 "additional information" callouts off
                clauses.push_back(json::array({"!=", coalesce(get("symbol_name"), ""), "INFORM01"}));
            // Meta-object coverage/region boundary lines (cell boundaries), gated
            // separately from "Other" (off by default).
            if (!m.showMetaBounds)
                clauses.push_back(json::array(
                    {"!", json::array({"in", coalesce(get("class"), ""),
                                       json::array({"literal", json::array({"M_NPUB", "M_NSYS", "M_COVR", "M_CSCL"})})})}));
            // Text-group selection on the text layers.
            if (isId(L, {"text", "light-text", "text-scamin", "light-text-scamin"}))
                clauses.push_back(textGroupFilter(m));
            andInto(L, clauses);
        }
    }
    return style.dump();
}

} // namespace chartstyle
