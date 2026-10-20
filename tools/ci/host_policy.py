"""The simulation runners' share of a hybrid host (docs/spec/verification.md §8; spikes.md §8.15): on a host with
P-cores and E-cores (/sys/devices/cpu_core/cpus and cpu_atom/cpus, as w-arrowlake's 0-7 and 8-23), Vivado runs on the
P-cores at nice 0 (tools/vivado_run.sh), and the runners' builds and simulations start at nice 10 or more, so a
Vivado job's threads take most of any P-core they share with a simulation, while the simulations still use the
P-cores when no Vivado job runs. A multi-threaded Verilator model is the exception: niced next to a nice-0 thread,
one of its threads waits and the others spin at every barrier, so it runs on the E-cores at the runner's own nice
instead. Elsewhere, or with TANAGER_SIM_POLICY=off, nothing changes. tools/ci/host_policy.sh is the shell side."""
import os

NICE = 10


def _cpus(path):
    try:
        text = open(path).read().strip()
    except OSError:
        return None
    cpus = set()
    for part in text.split(","):
        lo, _, hi = part.partition("-")
        cpus.update(range(int(lo), int(hi or lo) + 1))
    return cpus or None


def hybrid():
    """(P-cores, E-cores) as sets of CPU numbers on a hybrid host with the policy on, else None."""
    if os.environ.get("TANAGER_SIM_POLICY", "on") == "off":
        return None
    p, e = _cpus("/sys/devices/cpu_core/cpus"), _cpus("/sys/devices/cpu_atom/cpus")
    return (p, e) if p and e else None


def _nice_up():
    if os.getpriority(os.PRIO_PROCESS, 0) < NICE:
        os.setpriority(os.PRIO_PROCESS, 0, NICE)   # only ever raised: an unprivileged process cannot lower it


def apply_self(threads=1):
    """A runner whose models all have THREADS threads: this process, and so everything it starts, at nice 10 or
    more (one thread), or on the E-cores (more), on a hybrid host. Returns a line for the runner's log, or None."""
    hy = hybrid()
    if hy is None:
        return None
    if threads > 1:
        os.sched_setaffinity(0, hy[1])
        return f"host policy: hybrid host, {threads}-thread models on the E-cores"
    _nice_up()
    return f"host policy: hybrid host, builds and simulations at nice {os.getpriority(os.PRIO_PROCESS, 0)}"


def preexec(threads=1):
    """A subprocess preexec_fn for a runner that also starts multi-threaded models: a model of more than one
    thread (with the checker that reads it) on the E-cores at the runner's nice, anything else at nice 10 or
    more. None elsewhere."""
    hy = hybrid()
    if hy is None:
        return None
    if threads > 1:
        e = hy[1]
        return lambda: os.sched_setaffinity(0, e)
    return _nice_up
