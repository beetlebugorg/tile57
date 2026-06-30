// Canonical Go binding to libtile57 (the chartplotter-native chart engine), living
// with the engine so it tracks the C ABI. Requires CGO + a built zig-out/lib/
// libtile57.a; see README.md. No third-party deps — stdlib + cgo only.
module github.com/beetlebugorg/chartplotter-native/bindings/go

go 1.23
