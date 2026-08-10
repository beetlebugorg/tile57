#!/usr/bin/env bash
# Print the Homebrew formula for a released version, reading each archive's
# sha256 out of <dist-dir> (the tarballs that release.yml just published).
# The tap job pipes this into Formula/tile57.rb.
#
# Usage: brew-formula.sh <version> <dist-dir>
set -euo pipefail

version="$1"
dist="$2"
base="https://github.com/beetlebugorg/tile57/releases/download/v$version"

sha() { shasum -a 256 "$dist/tile57-$version-$1.tar.gz" | cut -d' ' -f1; }

# Resolved before the heredoc: a command substitution that fails inside one is
# not caught by `set -e`, and a missing archive would emit an empty sha256.
mac_arm="$(sha aarch64-macos)"
mac_intel="$(sha x86_64-macos)"
linux_arm="$(sha aarch64-linux-gnu)"
linux_intel="$(sha x86_64-linux-gnu)"

cat <<EOF
class Tile57 < Formula
  desc "Nautical chart engine: IHO S-101 and S-57 charts to tiles, PNG, and PDF"
  homepage "https://github.com/beetlebugorg/tile57"
  version "$version"
  license "MIT"

  on_macos do
    on_arm do
      url "$base/tile57-$version-aarch64-macos.tar.gz"
      sha256 "$mac_arm"
    end
    on_intel do
      url "$base/tile57-$version-x86_64-macos.tar.gz"
      sha256 "$mac_intel"
    end
  end

  on_linux do
    on_arm do
      url "$base/tile57-$version-aarch64-linux-gnu.tar.gz"
      sha256 "$linux_arm"
    end
    on_intel do
      url "$base/tile57-$version-x86_64-linux-gnu.tar.gz"
      sha256 "$linux_intel"
    end
  end

  def install
    bin.install "bin/tile57"
    lib.install "lib/libtile57.a"
    include.install "include/tile57.h"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/tile57 version 2>&1")
  end
end
EOF
