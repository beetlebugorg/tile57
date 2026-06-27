// MarinerSettings — the S-52 mariner display options, client-side.
//
// Cross-platform and dependency-free (no Qt, no mbgl): any client (the Qt desktop
// viewer today, mobile later) holds one of these and hands it to ChartStyle::build
// to produce a MapLibre style. Mirrors the `mariner` object in the Go project's web
// client (chartplotter/web/src/chart-canvas/s52-style.mjs) field-for-field, so the
// two stay in parity. Defaults match that client's defaults.
//
// Some axes are applied today; others need the Zig engine to bake their per-feature
// tag first (cat/bnd/pts/sleg/tgrp/date_*) — see ChartStyle::build. The struct
// carries them all now so the model and UI are complete and forward-compatible.
#pragma once

#include <string>

namespace chartstyle {

enum class Scheme { Day, Dusk, Night };
enum class DepthUnit { Meters, Feet };
enum class BoundaryStyle { Symbolized, Plain }; // S-52 §8.6.1 (default symbolized)

struct MarinerSettings {
    // -- colour scheme (S-52 day/dusk/night palette) --
    Scheme scheme = Scheme::Day;

    // -- depth (SEABED01, client-side shading; metres) --
    double shallowContour = 2.0;
    double safetyContour = 10.0; // the mariner's own-ship safety contour
    double deepContour = 30.0;
    double safetyDepth = 10.0;       // SNDFRM04 bold/faint sounding split
    bool fourShadeWater = true;      // 4 depth shades (vs 2)
    DepthUnit depthUnit = DepthUnit::Meters;

    // -- display category (S-52 §10.3.4, multi-select) [needs engine `cat`] --
    bool displayBase = true;
    bool displayStandard = true;
    bool displayOther = false;

    // -- overlays / opt-in markers (off by default) --
    bool dataQuality = false;          // M_QUAL / CATZOC zone-of-confidence overlay
    bool showInformCallouts = false;   // INFORM01 "additional info" callouts ("flyouts")
    bool showMetaBounds = false;       // cell/coverage boundary lines (M_NPUB/M_NSYS/M_COVR/M_CSCL)
    bool showIsolatedDangersShallow = false; // ISODGR01 in shallow water (Standard vs Base)

    // -- symbolization style [bnd/pts/sleg need engine tags] --
    BoundaryStyle boundaryStyle = BoundaryStyle::Symbolized;
    bool simplifiedPoints = false;     // simplified vs paper-chart point symbols
    bool showFullSectorLines = false;  // full VALNMR sector legs vs 25 mm short

    // -- text groups (S-52 §14.5) [needs engine `tgrp`] --
    bool textNames = true;
    bool showLightDescriptions = true;
    bool textOther = true;

    // -- date-dependent display (S-52 §10.4.1.1) [needs engine date_* tags] --
    bool dateDependent = true;         // hide features outside their validity period
    bool highlightDateDependent = false; // CHDATD01 marker (opt-in)
    std::string dateView;              // pinned viewing date "YYYYMMDD" (empty = today)
};

} // namespace chartstyle
