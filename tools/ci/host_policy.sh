# The simulation runners' share of a hybrid host, for shell runners (sourced; tools/ci/host_policy.py has the
# reasons; docs/spec/verification.md §8). TANAGER_SIM_POLICY=off turns it off.
#   host_policy_hybrid        true on a host with P-cores and E-cores (/sys/devices/cpu_core, cpu_atom)
#   host_policy_ecores        the E-cores, as taskset takes them ("8-23")
#   host_policy_nice PID      on a hybrid host, PID (a runner: what it starts inherits it) to nice 10 or more
host_policy_hybrid() {
  [ "${TANAGER_SIM_POLICY:-on}" != off ] && [ -s /sys/devices/cpu_core/cpus ] && [ -s /sys/devices/cpu_atom/cpus ]
}
host_policy_ecores() { cat /sys/devices/cpu_atom/cpus; }
host_policy_nice() {
  host_policy_hybrid || return 0
  local cur
  cur=$(ps -o ni= -p "$1" | tr -d ' ')
  if [ "${cur:-0}" -lt 10 ] 2>/dev/null; then renice -n 10 -p "$1" > /dev/null; fi
  return 0
}
