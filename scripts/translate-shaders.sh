#!/bin/bash
# Translate the LSFG shaders from your own Lossless.dll into a Metal library.
#
#   DXBC (Lossless.dll) --dxbc-spirv--> SPIR-V --SPIRV-Cross--> MSL --metal--> lsfg.metallib
#
# Output goes to ~/Library/Caches/lsfg-metal/<dll sha256>/ (never into the repo).
# Needs: dxbc_compiler (github.com/doitsujin/dxbc-spirv, built with -Denable_tools=true),
#        spirv-cross and spirv-tools (brew install spirv-cross spirv-tools), Xcode.
set -euo pipefail

DXBC_COMPILER=${DXBC_COMPILER:-dxbc_compiler}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v "$DXBC_COMPILER" >/dev/null || { echo "set DXBC_COMPILER to the dxbc_compiler binary" >&2; exit 1; }

DLL=${LSFG_DLL:-$(swift run --package-path "$ROOT" -q lsfg-metal locate | awk '/^dll:/{sub(/^dll: +/,""); print; exit}')}
[ -f "$DLL" ] || { echo "Lossless.dll not found" >&2; exit 1; }
HASH=$(shasum -a 256 "$DLL" | cut -c1-16)
OUT=${LSFG_CACHE:-$HOME/Library/Caches/lsfg-metal}/$HASH
mkdir -p "$OUT"/{dxbc,spv,msl,air,log}

swift run --package-path "$ROOT" -q lsfg-metal dump --dll "$DLL" --out "$OUT/dxbc" >/dev/null

translate() {
    local n=$1 out=$2
    "$DXBC_COMPILER" "$out/dxbc/$n.dxbc" --spv "$out/spv/$n.spv" >"$out/log/$n.txt" 2>&1
    spirv-cross "$out/spv/$n.spv" --msl --msl-version 30000 --rename-entry-point main "lsfg_$n" comp \
        --output "$out/msl/$n.metal" >>"$out/log/$n.txt" 2>&1
    # SPIRV-Cross references gl_WorkGroupSize for LocalSizeId modes without declaring it.
    if grep -q gl_WorkGroupSize "$out/msl/$n.metal" && ! grep -q 'gl_WorkGroupSize =' "$out/msl/$n.metal"; then
        local size
        size=$(spirv-dis "$out/spv/$n.spv" | sed -nE 's/.*LocalSizeId %main %uint_([0-9]+) %uint_([0-9]+) %uint_([0-9]+).*/\1u, \2u, \3u/p')
        sed -i '' "s/^using namespace metal;/using namespace metal;\nconstant uint3 gl_WorkGroupSize = uint3($size);/" "$out/msl/$n.metal"
    fi
    xcrun -sdk macosx metal -std=metal3.0 -O3 -c "$out/msl/$n.metal" -o "$out/air/$n.air" >>"$out/log/$n.txt" 2>&1
}
export -f translate
export DXBC_COMPILER

ls "$OUT/dxbc" | sed 's/\.dxbc$//' | xargs -P "$(sysctl -n hw.ncpu)" -I{} bash -c 'translate {} "$0" || echo "FAILED {} (see $0/log/{}.txt)"' "$OUT"
xcrun -sdk macosx metallib "$OUT"/air/*.air -o "$OUT/lsfg.metallib"
echo "$OUT/lsfg.metallib ($(ls "$OUT/air" | wc -l | tr -d ' ') kernels)"
