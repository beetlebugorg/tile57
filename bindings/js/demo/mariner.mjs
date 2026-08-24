// The S-52 mariner settings model: the JS mirror of tile57_mariner, its
// persistence, and the declarative rows the settings panel renders. The
// engine's own canonical defaults (tile57_mariner_defaults, fetched from the
// worker at boot) seed the model; localStorage carries the mariner's changes.
//
// Keys are the wrapper's (tile57.mjs allocMariner): the three display_*
// booleans collapse into one cumulative `detailLevel` here (S-52 §10.2 - each
// level implies the ones below it), and `soundings` is the tri-state override
// every ECDIS gives its own switch.

const KEY = "tile57.mariner";
const M_TO_FT = 3.28084;

// Recreational depth defaults over the engine's ship-scale canon. The S-52
// defaults (safety contour 10 m) suit SOLAS drafts; a sailboat draws about
// 2 m, and a 10 m safety contour paints most of a harbor as unsafe. The
// mariner's own stored settings still win over these.
const RECREATIONAL = { shallowContour: 2, safetyContour: 3, deepContour: 10, safetyDepth: 3 };

export function loadStored(defaults) {
  let stored = {};
  try {
    stored = JSON.parse(localStorage.getItem(KEY)) || {};
  } catch { /* first visit */ }
  return { ...defaults, ...RECREATIONAL, ...stored };
}
export function saveStored(m) {
  try {
    localStorage.setItem(KEY, JSON.stringify(m));
  } catch { /* private mode */ }
}

export const SCHEMES = ["day", "dusk", "night"];

// The settings rows, grouped the way the spec groups them. Each item:
// {key, type, label, desc?, options?, unit?, transform?} - the same shapes the
// chartplotter settings dialog renders.
export function settingsGroups(m) {
  const ft = m.depthUnit === "ft";
  const depth = (key, label) => ({
    key, type: "number", label,
    unit: ft ? "ft" : "m",
    step: ft ? "1" : "0.1",
    transform: {
      toView: (v) => (ft ? Math.round(v * M_TO_FT) : v),
      fromView: (v) => (ft ? v / M_TO_FT : v),
    },
  });
  return [
    {
      group: "Detail level",
      items: [{
        key: "detailLevel", type: "segmented", label: "Detail level",
        desc: "Display Base is always shown - Standard adds normal chart content, Other adds every remaining feature",
        options: [["base", "Base"], ["standard", "Standard"], ["other", "Other"]],
      }],
    },
    {
      group: "Water & depths",
      items: [
        { key: "fourShadeWater", type: "toggle", label: "Four-shade water", desc: "Use four depth shades instead of two" },
        {
          key: "soundings", type: "segmented", label: "Spot soundings",
          desc: "Individual depth soundings, independent of the detail level",
          options: [["auto", "Auto"], ["on", "On"], ["off", "Off"]],
        },
        { key: "depthUnit", type: "segmented", label: "Depth unit", options: [["m", "Metres"], ["ft", "Feet"]] },
        depth("shallowContour", "Shallow contour"),
        depth("safetyContour", "Safety contour"),
        depth("deepContour", "Deep contour"),
        depth("safetyDepth", "Safety depth"),
      ],
    },
    {
      group: "Symbols & lines",
      items: [
        {
          key: "boundaryStyle", type: "segmented", label: "Area boundaries", desc: "Line style for area edges",
          options: [["plain", "Plain"], ["symbolized", "Symbolized"]],
        },
        {
          key: "simplifiedPoints", type: "segmented", label: "Point symbols", desc: "Buoy & beacon symbol style",
          options: [["paper", "Paper-chart"], ["simplified", "Simplified"]],
          transform: { toView: (b) => (b ? "simplified" : "paper"), fromView: (s) => s === "simplified" },
        },
        { key: "showFullSectorLines", type: "toggle", label: "Full sector lines", desc: "Draw light sectors to full range, not short stubs" },
      ],
    },
    {
      group: "Text",
      items: [
        { key: "showLightDescriptions", type: "toggle", label: "Light descriptions", desc: "Light characteristics, e.g. Fl(2)R 10s" },
        { key: "textNames", type: "toggle", label: "Names", desc: "Buoy, beacon & place names, berth numbers" },
        { key: "textOther", type: "toggle", label: "Other text", desc: "Notes, seabed, magnetic variation, heights" },
      ],
    },
    {
      group: "Dangers & boundaries",
      items: [
        { key: "showIsolatedDangersShallow", type: "toggle", label: "Isolated dangers (shallow)", desc: "Also flag isolated dangers in shallow water" },
        { key: "dataQuality", type: "toggle", label: "Data quality", desc: "Survey zones-of-confidence overlay" },
        { key: "showInformCallouts", type: "toggle", label: "Information callouts", desc: "“Additional information available” markers on features that carry notes" },
        { key: "showMetaBounds", type: "toggle", label: "Metadata boundaries", desc: "Chart coverage & region indicator lines" },
        { key: "showOverscale", type: "toggle", label: "Overscale pattern", desc: "Hatch areas displayed beyond their chart's compilation scale" },
      ],
    },
    {
      group: "Dates",
      items: [
        { key: "dateDependent", type: "toggle", label: "Hide out-of-date features", desc: "Hide seasonal or expired features outside their validity dates" },
        { key: "highlightDateDependent", type: "toggle", label: "Highlight date-dependent", desc: "Mark features that carry date conditions with the “d” symbol" },
        { key: "dateView", type: "date", label: "Viewing date", desc: "Evaluate date-dependent features against this date (blank = today)" },
      ],
    },
  ];
}
