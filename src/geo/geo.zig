//! Integer computational geometry for chart composition. Pure (std-only), so the
//! module self-tests via `zig build test`. The scene baker and the tile
//! compositor use it to decide which cell owns each tile.
//!
//!   * `boolean`   — a Martinez–Rueda–Feito polygon boolean (union / intersection
//!     / difference / symmetric-difference) on integer coordinates, with
//!     overlap-edge typing and a deterministic total order, plus `unionAll`.
//!   * `plane`     — the per-tier coverage partition (`ownedAtTier`), the FULL /
//!     EMPTY / SEAM tile classifier (`EdgeGrid`), and `clipLineOutsidePolys`.
//!   * `partition` — the cell-ownership partition and its `.tpart` sidecar
//!     (`serialize` / `deserialize` / `inputKey`).

pub const boolean = @import("boolean.zig");
pub const plane = @import("plane.zig");
pub const partition = @import("partition.zig");

test {
    _ = boolean;
    _ = plane;
    _ = partition;
}
