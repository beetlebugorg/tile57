//! style-parity — the NATIVE oracle for the wasm style engine.
//!
//! It embeds the SAME template + colortables as bindings/wasm/style_wasm.zig and
//! drives the SAME `chartstyle.buildStyle` through the SAME shared settings
//! parser — only the compilation target differs (native vs wasm32). So a diff of
//! this tool's output against the wasm/JS output for identical settings + now_unix
//! is a true byte-for-byte parity check of the engine across the two backends.
//!
//! usage: style-parity <settings.json> <now_unix> <out.json>
//!   settings.json : mariner-settings JSON blob (same schema the JS API sends)
//!   now_unix      : fixed Unix epoch seconds (so "today" is deterministic)
//!   out.json      : output path for the generated MapLibre style.json

const std = @import("std");
const assets = @import("assets");
const chartstyle = @import("assets").chartstyle;
const settings = @import("settings");

const template_json = @embedFile("template_json");
const colortables_json = @embedFile("colortables_json");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);

    if (args.len < 4) {
        std.debug.print("usage: style-parity <settings.json> <now_unix> <out.json>\n", .{});
        return error.Usage;
    }
    const settings_json = try std.Io.Dir.cwd().readFileAlloc(io, args[1], a, .unlimited);
    const now_unix = try std.fmt.parseInt(i64, args[2], 10);
    const out_path = args[3];

    const m = settings.parse(a, settings_json);
    const style = try assets.buildFromTemplate(a, template_json, &m, colortables_json, null, now_unix);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = style });
    std.debug.print("style-parity: wrote {s} ({d} bytes)\n", .{ out_path, style.len });
}
