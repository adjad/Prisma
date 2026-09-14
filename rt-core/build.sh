#!/bin/sh
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror -dynamiclib RtCore.mm MetalFxFrame.mm -framework Foundation -framework Metal -framework MetalFX -o build/librtcore.dylib
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror Proof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/rt-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror VisibilityProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -framework ImageIO -framework CoreGraphics -o build/visibility-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror FrameProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/frame-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror TransportProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/transport-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror TemporalProof.mm -framework Foundation -framework Metal -o build/temporal-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror TransmissionProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/transmission-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror TransparencyFrameProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/transparency-frame-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror MetalFxProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/metalfx-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror DynamicFrameProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/dynamic-frame-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror TransmissionGiProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/transmission-gi-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror EdgeFrameProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/edge-frame-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror ChunkProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/chunk-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror AttributeFrameProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/attribute-frame-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror AreaLightProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/area-light-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror AreaLightFrameProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/area-light-frame-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror LightSamplingProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/light-sampling-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror LocalTransportProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/local-transport-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror PhysicalLightingProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/physical-lighting-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror DirectSpecularProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/direct-specular-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror HdrFrameProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/hdr-frame-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror MetalFxDynamicProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/metalfx-dynamic-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror MetalFxShadowProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/metalfx-shadow-proof
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror MetalFxReflectionProof.mm -Lbuild -lrtcore -Wl,-rpath,@executable_path -framework Foundation -framework Metal -o build/metalfx-reflection-proof
