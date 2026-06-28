//! The S-101 PortrayalCatalog assets, embedded into the tile57 CLI. build.zig's
//! `embedDir` walks each catalogue subdirectory at configure time and generates a
//! registry module of `@embedFile`'d entries (`.name` = file stem, `.bytes` =
//! content); this re-exports them under friendly names. bake.zig draws on these
//! to emit colortables / sprites / patterns / styles with no on-disk catalogue —
//! an explicit --catalog / positional dir overrides them (reads from disk).
//!
//! Each registry defines its own structurally-identical `Entry` type; callers
//! read `.name` / `.bytes` and don't depend on the nominal type.

pub const symbols = @import("symbols_registry").entries; // Symbols/*.svg  (id = stem)
pub const css = @import("css_registry").entries; // Symbols/*.css  (daySvgStyle, …)
pub const linestyles = @import("linestyles_registry").entries; // LineStyles/*.xml
pub const areafills = @import("areafills_registry").entries; // AreaFills/*.xml
pub const colorprofile = @import("colorprofile_registry").entries; // ColorProfiles/*.xml (one)
