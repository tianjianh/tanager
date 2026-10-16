# SoC-track software environment. Source after tools/env.sh:
#   source tools/env.sh && source sw/env.sh
# Build trees go under $TANAGER_BUILD/<worktree-name> (conventions §1, §9).
_sw_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_sw_here/versions.sh"
export SOC_ROOT="$(cd "$_sw_here/.." && pwd)"
export SOC_BUILD="${SOC_BUILD:-${TANAGER_BUILD:-$HOME/tanager-build}/$(basename "$SOC_ROOT")}"
export SOC_DL="${SOC_DL:-$SOC_BUILD/dl}"          # the one shared download directory (Buildroot BR2_DL_DIR too)
export SOC_JOBS="${SOC_JOBS:-8}"                   # conventions §9: at most -j8 per track
# The external toolchains (sw/versions.sh), unpacked once each: this worktree's $SOC_BUILD/tc if it has
# one, else the shared $SOC_TC_SHARED ($TANAGER_BUILD/tc) that every worktree and CI can use. sw/fetch.sh
# and sw/build_opensbi.sh unpack a missing one into $SOC_TC_DIR (default $SOC_BUILD/tc; set it to
# $SOC_TC_SHARED to share it).
export SOC_TC_SHARED="${SOC_TC_SHARED:-${TANAGER_BUILD:-$HOME/tanager-build}/tc}"
_sw_tc() { if [ ! -d "$SOC_BUILD/tc/$1/bin" ] && [ -d "$SOC_TC_SHARED/$1/bin" ]; then echo "$SOC_TC_SHARED/$1"; else echo "$SOC_BUILD/tc/$1"; fi; }
export SOC_AATC="${SOC_AATC:-$(_sw_tc "$AATC_NAME")}"   # aarch64 musl: tanager-host
export SOC_RVTC="${SOC_RVTC:-$(_sw_tc "$RVTC_NAME")}"   # riscv64 glibc: OpenSBI
unset -f _sw_tc
unset _sw_here
