//! Integer computational geometry for cross-band chart composition — the geometry
//! core, not yet wired to the baker, the live oracle, or the client:
//!
//!   * `boolean` — a Martinez–Rueda–Feito polygon boolean (union / intersection /
//!     difference / symmetric-difference) on integer coordinates, with
//!     overlap-edge typing and a deterministic total order, plus `unionAll`.
//!   * `plane`   — the per-tier coverage partition (`ownedAtTier`), the FULL /
//!     EMPTY / SEAM tile classifier (`EdgeGrid`), and `clipLineOutsidePolys`.
//!
//! Both are pure (std-only) so they self-test via `zig build test`.

pub const boolean = @import("boolean.zig");
pub const plane = @import("plane.zig");

test {
    _ = boolean;
    _ = plane;
}
