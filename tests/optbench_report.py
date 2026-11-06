"""Turn tests/optbench.sh's results.tsv into markdown tables.

One table per metric: a row per program, a column per config. Time is
also shown as speedup over the naive config. A metric that's the same in
every config of a program is still shown, so a missing effect is visible.
"""
import sys
from collections import OrderedDict

# (metric, title, what it means)
METRICS = [
    ("seconds", "Wall-clock seconds per run (min over rounds)", ""),
    ("spread", "Timing spread (max/min over rounds)",
     "a noise check: a speedup smaller than this is within the noise"),
    ("trail_pushes", "Trail entries pushed", "every entry, choice points included"),
    ("max_trail", "Trail high-water mark", "entries"),
    ("skipped_nondet", "Rewrites #1 didn't trail", ""),
    ("skipped_epoch", "Rewrites #5 didn't trail", ""),
    ("barrier_lowered", "Rewrites whose new nodes the barrier stamped old", ""),
    ("scoped_hits", "Scoped retries that flipped a choice (#3)", ""),
    ("scoped_retries", "Scoped retries tried (#3)", ""),
    ("copy_collapses", "Collapses done as copies (#4)", ""),
    ("forward_hops", "Forward nodes followed by readers", ""),
    ("compressions", "Forwards retargeted by path compression", ""),
    ("compress_hops_skipped", "Hops path compression skipped", ""),
    ("tail_calls", "Generated tail calls (#2 makes each a direct jump)", ""),
    ("allocations", "Allocations", ""),
]


def main(path):
    data = {}
    programs = OrderedDict()
    configs = OrderedDict()
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 4:
            continue
        prog, conf, key, val = parts
        programs[prog] = None
        configs[conf] = None
        data[(prog, conf, key)] = val
    programs, configs = list(programs), list(configs)

    print("# Backtracking optimization bench\n")
    print("Configs: `naive` has everything off (#2 included); `+x` adds one optimization to it;")
    print("`all` has everything on; `-x` removes one from it. The barrier is on")
    print("whenever #1 and #5 both are.\n")

    def status(p, c):
        return data.get((p, c, "status"), "ok")
    wrong = [(p, c) for p in programs for c in configs if status(p, c) == "MISMATCH"]
    other = [(p, c, status(p, c)) for p in programs for c in configs
             if status(p, c) not in ("ok", "MISMATCH")]
    if wrong:
        print("## Wrong output\n")
        for p, c in wrong:
            print(f"- `{p}` under `{c}`")
        print()
    else:
        print("Every run that finished matched its golden.\n")
    if other:
        # Usually a config with neither #1 nor #5 trailing every rewrite of a
        # big deterministic program until it runs out of memory or time.
        print("## Didn't finish\n")
        by = OrderedDict()
        for p, c, st in other:
            by.setdefault((p, st), []).append(c)
        for (p, st), cs in by.items():
            print(f"- `{p}`: {st} under " + ", ".join(f"`{c}`" for c in cs))
        print()

    def table(key, fmt):
        rows = [p for p in programs if any((p, c, key) in data for c in configs)]
        if not rows:
            return False
        print("| program | " + " | ".join(configs) + " |")
        print("|---|" + "---:|" * len(configs))
        for p in rows:
            cells = [fmt(p, c, data.get((p, c, key), "")) for c in configs]
            print(f"| {p.split('/')[-1].replace('.curry', '')} | " + " | ".join(cells) + " |")
        print()
        return True

    for key, title, note in METRICS:
        if not any(k == key for (_, _, k) in data):
            continue
        print(f"## {title}\n")
        if note:
            print(f"({note})\n")
        table(key, lambda p, c, v: v)
        if key == "seconds":
            for base_conf in ("naive", "default"):
                print(f"### Speedup over {base_conf}\n")
                if base_conf == "default":
                    print("(what each config gains or loses against what rice ships;"
                          " it also covers programs naive can't finish)\n")

                def speed(p, c, v, base_conf=base_conf):
                    base = data.get((p, base_conf, "seconds"), "NA")
                    try:
                        return f"{float(base) / float(v):.2f}x"
                    except (ValueError, ZeroDivisionError):
                        return ""
                table("seconds", speed)


if __name__ == "__main__":
    main(sys.argv[1])
