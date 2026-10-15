#!/usr/bin/env python3
"""Compares runs of the Linux workload set (DR-141; docs/spec/verification.md §4.6).

    tglb_compare.py [--metric cycles|instret|ns] [NAME=]LOG[,LOG...] ...

Each LOG is a console log holding one run of tg-lbench.sh (anything else in it is skipped); several
logs for one NAME, one per boot say, are pooled. The first NAME is the base, for example one per
bitstream profile. Prints a Markdown table: per test, the median over the runs of the metric per
operation for each NAME, its change against the base, and the spread (the widest of the runs,
(max - min) / median, for any NAME), so a change within the spread is not a finding. A log that did
not finish, had a failing test, or has no cycle counts is reported above the table, and so is the
kernel's boot time to /init when the logs carry its timestamps. The output is ASCII.
"""
import argparse
import os
import re
import statistics
import sys

INIT = re.compile(r'\[\s*(\d+\.\d+)\]\s+Run /init as init process')


def parse(path):
    """Returns (header lines, problems, {test: [run dicts]}, [boot-to-init seconds]) for one log."""
    head, problems, tests, boots = [], [], {}, []
    began = ended = stopped = False
    with open(path, errors='replace') as f:
        for raw in f:
            line = raw.strip()
            m = INIT.search(line)
            if m:
                boots.append(float(m.group(1)))
                continue
            i = line.find('TGLB')  # a console may prefix the line (a timestamp, a carriage return)
            if i < 0:
                continue
            line = line[i:]
            word = line.split(None, 1)[0]
            if word == 'TGLB-BEGIN':
                if began:
                    problems.append('more than one run in the log; the runs are pooled')
                began = True
                head.append(line)
            elif word == 'TGLB-INFO':
                head.append(line)
                if 'counters=cycle' not in line:
                    problems.append('no cycle counts (counters=time): ' + line)
            elif word == 'TGLB-END':
                ended = True
                head.append(line)
                if 'status=0' not in line.split():
                    problems.append(line)
            elif word == 'TGLB-FAIL':
                problems.append(line)
            elif word == 'TGLB':
                parts = line.split()
                if len(parts) < 3:
                    continue
                kv = dict(p.split('=', 1) for p in parts[2:] if '=' in p)
                tests.setdefault(parts[1], []).append(kv)
                if kv.get('cycles') == '0' and not stopped:
                    stopped = True  # a tg-lbench without the perf start (before 8fd41b3) reads stopped counters
                    problems.append('cycles=0: the counters were not running: ' + line)
    if not began:
        problems.append('no TGLB-BEGIN line')
    elif not ended:
        problems.append('no TGLB-END line: the run did not finish')
    return head, problems, tests, boots


def per_op(run, metric):
    v, ops = run.get(metric, '-'), run.get('ops', '0')
    if v == '-' or not v.isdigit() or not ops.isdigit() or int(ops) == 0:
        return None
    return int(v) / int(ops)


def fmt(v):
    if v >= 100:
        return f'{v:,.0f}'
    if v >= 1:
        return f'{v:.2f}'
    return f'{v:.4f}'


def spread(vals):
    m = statistics.median(vals)
    return (max(vals) - min(vals)) / m if m > 0 else 0.0


def main():
    sys.stdout.reconfigure(errors='replace')  # a Windows console's code page cannot fail the report
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--metric', choices=('cycles', 'instret', 'ns'), default='cycles')
    ap.add_argument('logs', nargs='+', metavar='[NAME=]LOG[,LOG...]')
    a = ap.parse_args()

    names, data, boots = [], [], []
    for spec in a.logs:
        name, paths = spec.split('=', 1) if '=' in spec and not os.path.exists(spec) else (spec, spec)
        tests, nboot = {}, []
        for path in paths.split(','):
            head, problems, t, b = parse(path)
            for k, runs in t.items():
                tests.setdefault(k, []).extend(runs)
            nboot += b
            print(f'- **{name}** (`{path}`): ' + ('; '.join(head) or 'no header'))
            for p in problems:
                print(f'  - problem: {p}')
        names.append(name)
        data.append(tests)
        boots.append(nboot)
    if all(boots):
        base = statistics.median(boots[0])
        cells = []
        for n, b in zip(names, boots):
            m = statistics.median(b)
            change = '' if n == names[0] else f', {(m / base - 1) * 100:+.2f}%'
            cells.append(f'{n} {m:.3f} s ({len(b)} boot{"s" if len(b) > 1 else ""}, spread {spread(b) * 100:.1f}%{change})')
        print('- **Linux boot to /init** (kernel log timestamps, median): ' + '; '.join(cells))
    print()

    order = []
    for tests in data:
        order += [t for t in tests if t not in order]
    cols = [f'{names[0]} {a.metric}/op'] + [f'{n} (change)' for n in names[1:]]
    print('| test | ' + ' | '.join(cols) + ' | spread |')
    print('|---' * (len(cols) + 2) + '|')
    for t in order:
        meds, noise = [], 0.0
        for tests in data:
            vals = [v for v in (per_op(r, a.metric) for r in tests.get(t, [])) if v is not None]
            if not vals:
                meds.append(None)
                continue
            meds.append(statistics.median(vals))
            noise = max(noise, spread(vals))
        base = meds[0]
        cells = [fmt(base) if base is not None else '-']
        for m in meds[1:]:
            if m is None:
                cells.append('-')
            elif base is None or base == 0:
                cells.append(fmt(m))
            else:
                cells.append(f'{fmt(m)} ({(m / base - 1) * 100:+.1f}%)')
        print(f'| {t} | ' + ' | '.join(cells) + f' | {noise * 100:.1f}% |')
    return 0


if __name__ == '__main__':
    sys.exit(main())
