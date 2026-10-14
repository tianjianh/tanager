# SoC-track software environment. Source after tools/env.sh:
#   source tools/env.sh && source sw/env.sh
# Build trees go under $TANAGER_BUILD/<worktree-name> (conventions §1, §9).
_sw_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_sw_here/versions.sh"
export SOC_ROOT="$(cd "$_sw_here/.." && pwd)"
export SOC_BUILD="${SOC_BUILD:-${TANAGER_BUILD:-$HOME/tanager-build}/$(basename "$SOC_ROOT")}"
export SOC_DL="${SOC_DL:-$SOC_BUILD/dl}"          # the one shared download directory (Buildroot BR2_DL_DIR too)
export SOC_JOBS="${SOC_JOBS:-8}"                   # conventions §9: at most -j8 per track
unset _sw_here
