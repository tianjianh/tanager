#!/bin/bash
# A hand-run simulation under the runners' host policy (tools/ci/host_policy.py; docs/spec/verification.md §8):
# on a hybrid host a single-threaded model at nice 10 or more, a multi-threaded one (-t N, N > 1: Verilator's
# --threads, tb_boot's VTHREADS) on the E-cores; elsewhere, or with TANAGER_SIM_POLICY=off, the command as it is.
#   tools/ci/simnice.sh [-t THREADS] COMMAND [ARGS...]
set -u
. "$(dirname "${BASH_SOURCE[0]}")/host_policy.sh"
threads=1
if [ "${1:-}" = -t ]; then threads=$2; shift 2; fi
[ $# -gt 0 ] || { echo "usage: $0 [-t THREADS] COMMAND [ARGS...]" >&2; exit 2; }
if host_policy_hybrid; then
  if [ "$threads" -gt 1 ]; then exec taskset -c "$(host_policy_ecores)" "$@"; fi
  host_policy_nice $$
fi
exec "$@"
