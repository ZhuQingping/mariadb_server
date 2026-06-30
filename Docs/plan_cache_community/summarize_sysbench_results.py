#!/usr/bin/env python3
"""Write summary.tsv from plan-cache sysbench results.tsv."""

import csv
import math
import statistics
import sys


def as_float(row, key):
    try:
        return float(row.get(key, "0") or "0")
    except (TypeError, ValueError):
        return 0.0


def is_valid(row):
    return row.get("valid", "1") != "0"


def median(values):
    return statistics.median(values) if values else 0.0


def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * pct
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (rank - lo)


def cv_pct(values):
    if len(values) < 2:
        return 0.0
    avg = statistics.mean(values)
    if avg == 0:
        return 0.0
    return statistics.pstdev(values) / avg * 100.0


def pct_delta(new_value, old_value):
    return (new_value / old_value - 1.0) * 100.0 if old_value else 0.0


def summarize(input_path, output_path):
    with open(input_path, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))

    groups = {}
    invalid_counts = {}
    for row in rows:
        key = (row["workload"], row["threads"])
        groups.setdefault(key, {}).setdefault(row["repeat"], {})[row["mode"]] = row
        if not is_valid(row):
            invalid_counts[key] = invalid_counts.get(key, 0) + 1

    fields = [
        "workload",
        "threads",
        "repeats",
        "invalid_samples",
        "off_tps_median",
        "on_tps_median",
        "tps_delta_pct",
        "off_qps_median",
        "on_qps_median",
        "qps_delta_pct",
        "off_qps_p25",
        "off_qps_p75",
        "off_qps_cv_pct",
        "on_qps_p25",
        "on_qps_p75",
        "on_qps_cv_pct",
        "off_cpu_median",
        "on_cpu_median",
        "cpu_delta_pct",
        "off_cpu_per_kqps",
        "on_cpu_per_kqps",
        "cpu_per_kqps_delta_pct",
        "on_hit_delta_median",
        "on_invalid_delta_sum",
        "on_live_count_max_median",
    ]

    with open(output_path, "w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        for workload, threads in sorted(groups, key=lambda x: (x[0], int(x[1]))):
            off = []
            on = []
            for repeat_rows in groups[(workload, threads)].values():
                off_row = repeat_rows.get("OFF")
                on_row = repeat_rows.get("ON")
                if off_row and on_row and is_valid(off_row) and is_valid(on_row):
                    off.append(off_row)
                    on.append(on_row)
            if not off or not on:
                continue
            off_tps = [as_float(r, "tps") for r in off]
            on_tps = [as_float(r, "tps") for r in on]
            off_qps = [as_float(r, "qps") for r in off]
            on_qps = [as_float(r, "qps") for r in on]
            off_cpu = [as_float(r, "cpu_avg_pct") for r in off]
            on_cpu = [as_float(r, "cpu_avg_pct") for r in on]
            off_tps_med, on_tps_med = median(off_tps), median(on_tps)
            off_qps_med, on_qps_med = median(off_qps), median(on_qps)
            off_cpu_med, on_cpu_med = median(off_cpu), median(on_cpu)
            off_cpu_per = off_cpu_med / off_qps_med * 1000.0 if off_qps_med else 0.0
            on_cpu_per = on_cpu_med / on_qps_med * 1000.0 if on_qps_med else 0.0
            writer.writerow(
                {
                    "workload": workload,
                    "threads": threads,
                    "repeats": min(len(off), len(on)),
                    "invalid_samples": invalid_counts.get((workload, threads), 0),
                    "off_tps_median": f"{off_tps_med:.2f}",
                    "on_tps_median": f"{on_tps_med:.2f}",
                    "tps_delta_pct": f"{pct_delta(on_tps_med, off_tps_med):.2f}",
                    "off_qps_median": f"{off_qps_med:.2f}",
                    "on_qps_median": f"{on_qps_med:.2f}",
                    "qps_delta_pct": f"{pct_delta(on_qps_med, off_qps_med):.2f}",
                    "off_qps_p25": f"{percentile(off_qps, 0.25):.2f}",
                    "off_qps_p75": f"{percentile(off_qps, 0.75):.2f}",
                    "off_qps_cv_pct": f"{cv_pct(off_qps):.2f}",
                    "on_qps_p25": f"{percentile(on_qps, 0.25):.2f}",
                    "on_qps_p75": f"{percentile(on_qps, 0.75):.2f}",
                    "on_qps_cv_pct": f"{cv_pct(on_qps):.2f}",
                    "off_cpu_median": f"{off_cpu_med:.2f}",
                    "on_cpu_median": f"{on_cpu_med:.2f}",
                    "cpu_delta_pct": f"{pct_delta(on_cpu_med, off_cpu_med):.2f}",
                    "off_cpu_per_kqps": f"{off_cpu_per:.4f}",
                    "on_cpu_per_kqps": f"{on_cpu_per:.4f}",
                    "cpu_per_kqps_delta_pct": f"{pct_delta(on_cpu_per, off_cpu_per):.2f}",
                    "on_hit_delta_median": f"{median([as_float(r, 'hit_delta') for r in on]):.0f}",
                    "on_invalid_delta_sum": f"{sum(as_float(r, 'invalid_delta') for r in on):.0f}",
                    "on_live_count_max_median": f"{median([as_float(r, 'live_count_max') for r in on]):.0f}",
                }
            )


def main(argv):
    if len(argv) != 3:
        print("usage: summarize_sysbench_results.py RESULTS_TSV SUMMARY_TSV", file=sys.stderr)
        return 2
    summarize(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
