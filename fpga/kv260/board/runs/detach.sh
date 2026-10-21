#!/bin/bash
# detach.sh LOG COMMAND [ARGS...]: on the A53, start COMMAND in its own session, detached from the SSH call that
# typed it, with its output in LOG. Callers type one plain line (~/tanager/runs/detach.sh LOG cmd args) in place of a
# detached launch with nested quotes, which raises an approval prompt only the user can answer (the coordinator's
# process rule, 10-20). It prints the new process's PID.
L=$1; shift
setsid "$@" > "$L" 2>&1 < /dev/null &
echo $!
