#!/usr/bin/env python3
"""Classify plan-cache sysbench summary rows by evidence strength."""

import argparse
import csv
import os
import statistics
import sys


def as_float(row, key):
    try:
        return float(row.get(key, "0") or "0")
    except ValueError:
        return 0.0


def row_label(row):
    phase = row.get("phase", "")
    rate = row.get("rate", "")
    workload = row.get("workload", "")
    threads = row.get("threads", "")
    if phase:
        return f"{phase}:{workload}:t{threads}:rate{rate}"
    return f"{workload}:t{threads}"


def source_label(row):
    source = row.get("_source", "")
    if not source:
        return ""
    parent = os.path.basename(os.path.dirname(source))
    name = os.path.basename(source)
    if parent:
        return f"{parent}/{name}"
    return name


def classify(row, min_qps_gain, min_efficiency_gain, max_cv):
    qps_gain = as_float(row, "qps_delta_pct")
    cpu_per_gain = -as_float(row, "cpu_per_kqps_delta_pct")
    invalidations = as_float(row, "on_invalid_delta_sum")
    invalid_samples = as_float(row, "invalid_samples")
    hits = as_float(row, "on_hit_delta_median")
    live_count = as_float(row, "on_live_count_max_median")
    on_cv = as_float(row, "on_qps_cv_pct")
    off_cv = as_float(row, "off_qps_cv_pct")
    workload = row.get("workload", "")
    phase = row.get("phase", "")
    low_variance = on_cv <= max_cv and off_cv <= max_cv

    if invalid_samples > 0:
        return "invalid", "invalid benchmark samples were excluded"
    if invalidations != 0 or hits <= 0 or live_count <= 0:
        return "invalid", "missing hit/live evidence or has invalidations"
    if phase == "fixed" and cpu_per_gain >= min_efficiency_gain and low_variance:
        if workload == "oltp_read_only":
            return "primary", "fixed-rate mixed read-only efficiency gain"
        return "strong", "fixed-rate supporting efficiency gain"
    if qps_gain >= min_qps_gain and low_variance:
        if workload == "oltp_read_only":
            return "primary", "mixed read-only gain with low variance"
        return "strong", "shape or supporting workload gain with low variance"
    if qps_gain > 0 or cpu_per_gain > 0:
        return "supporting", "positive QPS or CPU-per-kQPS efficiency signal"
    return "risk", "no positive throughput or efficiency signal"


def load_rows(paths):
    rows = []
    for path in paths:
        with open(path, newline="") as f:
            for row in csv.DictReader(f, delimiter="\t"):
                row["_source"] = path
                rows.append(row)
    return rows


def load_detail_rows(paths):
    rows = []
    for path in paths:
        with open(path, newline="") as f:
            for row in csv.DictReader(f, delimiter="\t"):
                row["_source"] = path
                rows.append(row)
    return rows


def detail_group_key(row):
    return (
        row.get("_source", ""),
        row.get("phase", ""),
        row.get("workload", ""),
        row.get("threads", ""),
        row.get("rate", ""),
        row.get("repeat", ""),
    )


def detail_case_key(row):
    return (
        row.get("_source", ""),
        row.get("phase", ""),
        row.get("workload", ""),
        row.get("threads", ""),
        row.get("rate", ""),
    )


def calculate_repeat_signals(rows):
    grouped = {}
    for row in rows:
        grouped.setdefault(detail_group_key(row), {})[row.get("mode", "")] = row

    signals = {}
    for _key, modes in grouped.items():
        off = modes.get("OFF")
        on = modes.get("ON")
        if not off or not on:
            continue
        case_key = detail_case_key(on)
        off_qps = as_float(off, "qps")
        on_qps = as_float(on, "qps")
        off_cpu_per = (
            as_float(off, "cpu_avg_pct") / off_qps * 1000.0 if off_qps else 0.0
        )
        on_cpu_per = (
            as_float(on, "cpu_avg_pct") / on_qps * 1000.0 if on_qps else 0.0
        )
        signals.setdefault(case_key, []).append(
            {
                "qps_delta_pct": (
                    (on_qps / off_qps - 1.0) * 100.0 if off_qps else 0.0
                ),
                "cpu_per_kqps_delta_pct": (
                    (on_cpu_per / off_cpu_per - 1.0) * 100.0
                    if off_cpu_per
                    else 0.0
                ),
                "lat_avg_delta_pct": (
                    (as_float(on, "lat_avg_ms") / as_float(off, "lat_avg_ms") - 1.0)
                    * 100.0
                    if as_float(off, "lat_avg_ms")
                    else 0.0
                ),
            }
        )
    return signals


def cv_pct(values):
    if len(values) < 2:
        return 0.0
    avg = statistics.mean(values)
    if avg == 0:
        return 0.0
    return statistics.pstdev(values) / avg * 100.0


def repeat_signal_label(key):
    source, phase, workload, threads, rate = key
    row = {
        "_source": source,
        "phase": phase,
        "workload": workload,
        "threads": threads,
        "rate": rate,
    }
    return row_label(row), source_label(row)


def print_section(title, rows):
    print(f"## {title}")
    if not rows:
        print("none")
        print()
        return
    print("| Case | Source | QPS delta % | CPU/kQPS delta % | ON CV % | Hits | Live count | Reason |")
    print("|---|---|---:|---:|---:|---:|---:|---|")
    for row, reason in rows:
        print(
            "| {case} | {source} | {qps:.2f} | {cpu:.2f} | {cv:.2f} | {hits:.0f} | {live:.0f} | {reason} |".format(
                case=row_label(row),
                source=source_label(row),
                qps=as_float(row, "qps_delta_pct"),
                cpu=as_float(row, "cpu_per_kqps_delta_pct"),
                cv=as_float(row, "on_qps_cv_pct"),
                hits=as_float(row, "on_hit_delta_median"),
                live=as_float(row, "on_live_count_max_median"),
                reason=reason,
            )
        )
    print()


def print_repeat_signals(signals):
    print("## Repeat-Level Signals")
    if not signals:
        print("none")
        print()
        return
    print("| Case | Source | Repeats | QPS positive | CPU/kQPS positive | QPS delta CV % | CPU/kQPS delta CV % |")
    print("|---|---|---:|---:|---:|---:|---:|")
    for key, values in sorted(signals.items(), key=lambda item: repeat_signal_label(item[0])):
        case, source = repeat_signal_label(key)
        qps = [item["qps_delta_pct"] for item in values]
        cpu = [-item["cpu_per_kqps_delta_pct"] for item in values]
        print(
            "| {case} | {source} | {repeats} | {qps_pos} | {cpu_pos} | {qps_cv:.2f} | {cpu_cv:.2f} |".format(
                case=case,
                source=source,
                repeats=len(values),
                qps_pos=sum(1 for item in qps if item > 0),
                cpu_pos=sum(1 for item in cpu if item > 0),
                qps_cv=cv_pct(qps),
                cpu_cv=cv_pct(cpu),
            )
        )
    print()


def print_gate_failures(failures):
    print("## Gate Failures")
    if not failures:
        print("none")
        print()
        return
    for item in failures:
        print(f"- {item}")
    print()


def parse_required_threads(value):
    if not value:
        return []
    return [item for item in value.replace(",", " ").split() if item]


def find_gate_failures(buckets, workload, required_threads):
    if not required_threads:
        return []

    primary_by_thread = {}
    for row, _reason in buckets["primary"]:
        if row.get("workload", "") == workload:
            primary_by_thread[row.get("threads", "")] = row

    failures = []
    for thread in required_threads:
        if thread not in primary_by_thread:
            failures.append(
                f"missing primary evidence for {workload}:t{thread}"
            )
    return failures


def find_repeat_gate_failures(signals, workload, required_threads, min_positive):
    if not required_threads or min_positive <= 0:
        return []

    failures = []
    for thread in required_threads:
        matches = [
            values
            for key, values in signals.items()
            if key[2] == workload and key[3] == thread
        ]
        if not matches:
            failures.append(f"missing repeat-level evidence for {workload}:t{thread}")
            continue
        positive = max(
            sum(1 for item in values if item["qps_delta_pct"] > 0)
            for values in matches
        )
        if positive < min_positive:
            failures.append(
                f"{workload}:t{thread} has only {positive} positive QPS repeats; "
                f"required {min_positive}"
            )
    return failures


def main():
    parser = argparse.ArgumentParser(
        description="Classify plan-cache sysbench summary.tsv evidence."
    )
    parser.add_argument("summary", nargs="+", help="summary TSV file(s)")
    parser.add_argument("--min-qps-gain", type=float, default=5.0)
    parser.add_argument("--min-efficiency-gain", type=float, default=8.0)
    parser.add_argument("--max-cv", type=float, default=5.0)
    parser.add_argument(
        "--require-primary-workload",
        default="oltp_read_only",
        help="workload name used with --require-primary-threads",
    )
    parser.add_argument(
        "--require-primary-threads",
        default="",
        help="space or comma separated thread counts that must classify as primary",
    )
    parser.add_argument(
        "--detail-results",
        nargs="*",
        default=[],
        help="raw results.tsv file(s) used for repeat-level evidence checks",
    )
    parser.add_argument(
        "--min-positive-repeats",
        type=int,
        default=0,
        help="minimum ON-vs-OFF positive QPS repeats for required primary threads",
    )
    args = parser.parse_args()

    rows = load_rows(args.summary)
    buckets = {
        "primary": [],
        "strong": [],
        "supporting": [],
        "risk": [],
        "invalid": [],
    }

    for row in rows:
        bucket, reason = classify(
            row, args.min_qps_gain, args.min_efficiency_gain, args.max_cv
        )
        buckets[bucket].append((row, reason))

    for values in buckets.values():
        values.sort(
            key=lambda item: (
                as_float(item[0], "qps_delta_pct"),
                -as_float(item[0], "on_qps_cv_pct"),
            ),
            reverse=True,
        )

    print_section("Primary Candidates", buckets["primary"])
    print_section("Strong Supporting Cases", buckets["strong"])
    print_section("Supporting Or Noisy Positive Cases", buckets["supporting"])
    print_section("Risk Or Regression Cases", buckets["risk"])
    print_section("Invalid Evidence Rows", buckets["invalid"])

    repeat_signals = calculate_repeat_signals(load_detail_rows(args.detail_results))
    print_repeat_signals(repeat_signals)

    gate_failures = find_gate_failures(
        buckets,
        args.require_primary_workload,
        parse_required_threads(args.require_primary_threads),
    )
    gate_failures.extend(
        find_repeat_gate_failures(
            repeat_signals,
            args.require_primary_workload,
            parse_required_threads(args.require_primary_threads),
            args.min_positive_repeats,
        )
    )
    print_gate_failures(gate_failures)

    if buckets["invalid"]:
        return 2
    if gate_failures:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
