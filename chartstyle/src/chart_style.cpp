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
json colorMatch(const json &tokenExpr, const json &palette) {
    json m = json::array({"match", tokenExpr});
    for (auto it = palette.begin(); it != palette.end(); ++it) {
        m.push_back(it.key());
        m.push_back(it.value());
    }
    m.push_back(FALLBACK);
    return m;
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
        // Depth shading is only regenerated when a palette is available; otherwise
        // keep the template's baked colours (avoids an all-magenta fallback).
        if (!palette.empty() && isId(L, {"fill-areas", "fill-areas_scamin"}))
            L["paint"]["fill-color"] = areasFillColor(palette, m);
        if (isId(L, {"soundings"}))
            L["layout"]["icon-image"] = soundingsIconImage(m);
        if (isId(L, {"point_symbols", "point_symbols_scamin", "point_symbols-north",
                     "point_symbols_scamin-north"}))
            L["layout"]["icon-image"] = pointSymbolImage(m);
        if (isId(L, {"contour-labels-lines", "contour-labels-lines_scamin"}))
            L["layout"]["text-field"] = contourLabelField(m);

        // Toggles applied to every chart-source layer. coalesce keeps features that
        // lack the property (so a missing class/symbol_name is never hidden).
        if (L.value("source", std::string()) == "chart") {
            std::vector<json> clauses;
            if (!m.dataQuality) // M_QUAL / CATZOC data-quality overlay off
                clauses.push_back(json::array({"!=", coalesce(get("class"), ""), "M_QUAL"}));
            if (!m.showInformCallouts) // INFORM01 "additional information" callouts off
                clauses.push_back(json::array({"!=", coalesce(get("symbol_name"), ""), "INFORM01"}));
            if (!clauses.empty()) andInto(L, clauses);
        }
    }
    return style.dump();
}

} // namespace chartstyle
