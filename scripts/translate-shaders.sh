#!/bin/bash
# Translate the shaders from your own Lossless.dll into one Metal library.
#
#   SPIR-V (IDs 303-400, LSFG 3.1) ------------------\
#   DXBC   (IDs 101-302) --dxbc-spirv--> SPIR-V -----+--SPIRV-Cross--> MSL --metal--> lsfg.metallib
#
# Output: ~/Library/Caches/lsfg-metal/<dll sha256>/ (never the repo).
#   lsfg.metallib   kernels named lsfg_<resource id>
#   groups.txt      "<id> <x> <y> <z>" threadgroup size per kernel
#
# Metal binding layout (from lsfg-vk's Vulkan layout):
#   buffer(b)   <- binding b       (uniform buffers, 0+)
#   sampler(s)  <- binding 16 + s
#   texture(t)  <- binding 32 + t  (sampled images 0-15, storage images 16+)
#
# Needs: spirv-cross, spirv-tools (brew), Xcode. DXBC needs DXBC_COMPILER
# (dxbc_compiler from github.com/doitsujin/dxbc-spirv); without it only SPIR-V is translated.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DXBC_COMPILER=${DXBC_COMPILER:-}

DLL=${LSFG_DLL:-$(swift run --package-path "$ROOT" -q lsfg-metal locate | awk '/^dll:/{sub(/^dll: +/,""); print; exit}')}
[ -f "$DLL" ] || { echo "Lossless.dll not found" >&2; exit 1; }
HASH=$(shasum -a 256 "$DLL" | cut -c1-16)
OUT=${LSFG_CACHE:-$HOME/Library/Caches/lsfg-metal}/$HASH
rm -rf "$OUT/air" "$OUT/msl"
mkdir -p "$OUT"/{src,spv,msl,air,log}

swift run --package-path "$ROOT" -q lsfg-metal dump --dll "$DLL" --out "$OUT/src" >/dev/null

translate() {
    local n=$1 out=$2 spv
    : >"$out/log/$n.txt"
    if [ -f "$out/src/$n.dxbc" ]; then
        [ -n "$DXBC_COMPILER" ] || return 0
        spv="$out/spv/$n.spv"
        "$DXBC_COMPILER" "$out/src/$n.dxbc" --spv "$spv" >>"$out/log/$n.txt" 2>&1
    else
        spv="$out/src/$n.spv"
    fi
    spirv-cross "$spv" --msl --msl-version 30000 --msl-decoration-binding \
        --rename-entry-point main "lsfg_$n" comp --output "$out/msl/$n.metal" >>"$out/log/$n.txt" 2>&1

    local dis size
    dis=$(spirv-dis "$spv")
    size=$(sed -nE 's/.*LocalSize ([0-9]+) ([0-9]+) ([0-9]+).*/\1 \2 \3/p; s/.*LocalSizeId %uint_([0-9]+) %uint_([0-9]+) %uint_([0-9]+).*/\1 \2 \3/p' <<<"$dis" | head -1)
    echo "$n $size" >"$out/air/$n.group"
    # SPIRV-Cross references gl_WorkGroupSize for LocalSizeId without declaring it.
    if grep -q gl_WorkGroupSize "$out/msl/$n.metal" && ! grep -q 'gl_WorkGroupSize =' "$out/msl/$n.metal"; then
        sed -i '' "s/^using namespace metal;/using namespace metal;\nconstant uint3 gl_WorkGroupSize = uint3(${size// /u, }u);/" "$out/msl/$n.metal"
    fi
    # Shift Vulkan binding ranges into Metal's argument tables.
    perl -pi -e 's/\[\[sampler\((\d+)\)\]\]/"[[sampler(".($1>=16?$1-16:$1).")]]"/ge; s/\[\[texture\((\d+)\)\]\]/"[[texture(".($1>=32?$1-32:$1).")]]"/ge' "$out/msl/$n.metal"
    xcrun -sdk macosx metal -std=metal3.0 -O3 -c "$out/msl/$n.metal" -o "$out/air/$n.air" >>"$out/log/$n.txt" 2>&1
}
export -f translate
export DXBC_COMPILER

ls "$OUT/src" | sed -E 's/\.(dxbc|spv)$//' | sort -n | xargs -P "$(sysctl -n hw.ncpu)" -I{} bash -c 'translate {} "$0" || echo "FAILED {} (see $0/log/{}.txt)"' "$OUT"
cat "$OUT"/air/*.group | sort -n >"$OUT/groups.txt"
xcrun -sdk macosx metallib "$OUT"/air/*.air -o "$OUT/lsfg.metallib"
echo "$OUT/lsfg.metallib ($(ls "$OUT"/air/*.air | wc -l | tr -d ' ') kernels)"
