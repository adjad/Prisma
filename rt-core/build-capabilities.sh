#!/bin/sh
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror MetalFXCapabilities.mm -framework Foundation -framework Metal -framework MetalFX -o build/metalfx-capabilities
