#!/usr/bin/env python3
"""Summarize plan-cache profile/status delta files."""

import argparse
import os
import re
import sys


PROFILE_COUNTERS = {
    "Cached_plan_profile_hit_build_us",
    "Cached_plan_profile_hit_explain_us",
    "Cached_plan_profile_hit_path_us",
    "Cached_plan_profile_hit_unique_build_us",
    "Cached_plan_profile_hit_unique_alloc_us",
    "Cached_plan_profile_hit_unique_read_us",
    "Cached_plan_profile_hit_unique_setup_plan_us",
    "Cached_plan_profile_hit_unique_setup_us",
    "Cached_plan_profile_hit_ref_build_us",
    "Cached_plan_profile_hit_ref_alloc_us",
    "Cached_plan_profile_hit_ref_setup_us",
    "Cached_plan_profile_hit_range_build_us",
    "Cached_plan_profile_hit_range_make_select_us",
    "Cached_plan_profile_hit_range_quick_select_us",
    "Cached_plan_profile_hit_range_setup_us",
    "Cached_plan_profile_hit_range_setup_alloc_us",
    "Cached_plan_profile_hit_range_setup_base_us",
    "Cached_plan_profile_hit_range_setup_distinct_us",
    "Cached_plan_profile_hit_range_setup_order_us",
    "Cached_plan_profile_hit_range_setup_ref_array_us",
    "Cached_plan_profile_hit_range_setup_aggr_us",
    "Cached_plan_profile_hit_range_setup_distinct_fast_us",
    "Cached_plan_profile_hit_range_setup_post_us",
    "Cached_plan_profile_prevalidate_us",
    "Cached_plan_profile_validate_us",
}

STATUS_COUNTERS = {
    "Handler_read_key",
    "Handler_read_next",
    "Handler_read_rnd_next",
    "Created_tmp_tables",
    "Created_tmp_disk_tables",
    "Table_open_cache_hits",
    "Table_open_cache_misses",
    "Table_open_cache_overflows",
    "Opened_tables",
    "Opened_table_definitions",
}


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def read_delta_file(path):
    values = {}
    with open(path, newline="") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4:
                continue
            values[parts[0]] = as_float(parts[3])
    return values


def case_label(path):
    name = os.path.basename(path)
    name = name.removesuffix(".status_delta.tsv")
    return name


def mode_from_label(label):
    match = re.search(r"_((?:ON)|(?:OFF))_r[0-9]+$", label)
    return match.group(1) if match else ""


def denominator_for(counter, values):
    if "_unique_" in counter:
        return values.get("Cached_plan_profile_hit_unique_count", 0.0)
    if "_ref_" in counter:
        return values.get("Cached_plan_profile_hit_ref_count", 0.0)
    if "_range_" in counter:
        return values.get("Cached_plan_profile_hit_range_count", 0.0)
    return values.get("Cached_plan_hits", 0.0)


def top_profile_rows(values, limit):
    rows = []
    for counter in PROFILE_COUNTERS:
        delta = values.get(counter, 0.0)
        if delta <= 0:
            continue
        denom = denominator_for(counter, values)
        if denom <= 0:
            continue
        per_hit = delta / denom if denom else 0.0
        rows.append((counter, delta, denom, per_hit))
    rows.sort(key=lambda row: (row[3], row[1]), reverse=True)
    return rows[:limit]


def print_case_summary(items, top):
    print("## Case Summary")
    if not items:
        print("none\n")
        return
    print("| Case | Mode | Hits | Invalidations | Top profile counter | us/hit | Delta us |")
    print("|---|---|---:|---:|---|---:|---:|")
    for path, values in items:
        label = case_label(path)
        rows = top_profile_rows(values, 1)
        if rows:
            counter, delta, _denom, per_hit = rows[0]
        else:
            counter, delta, per_hit = "", 0.0, 0.0
        print(
            "| {case} | {mode} | {hits:.0f} | {invalid:.0f} | {counter} | {per_hit:.6f} | {delta:.0f} |".format(
                case=label,
                mode=mode_from_label(label),
                hits=values.get("Cached_plan_hits", 0.0),
                invalid=values.get("Cached_plan_invalidations", 0.0),
                counter=counter or "none",
                per_hit=per_hit,
                delta=delta,
            )
        )
    print()


def print_profile_hotspots(items, top):
    print("## Profile Hotspots")
    rows = []
    for path, values in items:
        for counter, delta, denom, per_hit in top_profile_rows(values, top):
            rows.append((path, counter, delta, denom, per_hit))
    rows.sort(key=lambda row: (row[4], row[2]), reverse=True)
    if not rows:
        print("none\n")
        return
    print("| Case | Counter | Delta us | Denominator | us/hit |")
    print("|---|---|---:|---:|---:|")
    for path, counter, delta, denom, per_hit in rows[: top * max(1, len(items))]:
        print(
            "| {case} | {counter} | {delta:.0f} | {denom:.0f} | {per_hit:.6f} |".format(
                case=case_label(path),
                counter=counter,
                delta=delta,
                denom=denom,
                per_hit=per_hit,
            )
        )
    print()


def print_status_deltas(items):
    print("## Status Deltas")
    print("| Case | Handler key | Handler next | Tmp tables | Tmp disk | Table cache misses | Opened tables |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for path, values in items:
        print(
            "| {case} | {key:.0f} | {next:.0f} | {tmp:.0f} | {disk:.0f} | {miss:.0f} | {opened:.0f} |".format(
                case=case_label(path),
                key=values.get("Handler_read_key", 0.0),
                next=values.get("Handler_read_next", 0.0),
                tmp=values.get("Created_tmp_tables", 0.0),
                disk=values.get("Created_tmp_disk_tables", 0.0),
                miss=values.get("Table_open_cache_misses", 0.0),
                opened=values.get("Opened_tables", 0.0),
            )
        )
    print()


def per_hit(counter, values):
    denom = denominator_for(counter, values)
    if denom <= 0:
        return 0.0
    return values.get(counter, 0.0) / denom


def advice_for_case(path, values):
    label = case_label(path)
    mode = mode_from_label(label)
    hits = values.get("Cached_plan_hits", 0.0)
    invalidations = values.get("Cached_plan_invalidations", 0.0)
    if mode != "ON" or hits <= 0:
        return "ignore", "no ON hit evidence"
    if invalidations:
        return "invalid", "invalidations occurred; fix stability before profiling"

    hit_path = per_hit("Cached_plan_profile_hit_path_us", values)
    range_build = per_hit("Cached_plan_profile_hit_range_build_us", values)
    range_setup = per_hit("Cached_plan_profile_hit_range_setup_us", values)
    setup_post = per_hit("Cached_plan_profile_hit_range_setup_post_us", values)
    setup_aggr = per_hit("Cached_plan_profile_hit_range_setup_aggr_us", values)
    setup_distinct = per_hit("Cached_plan_profile_hit_range_setup_distinct_us", values)
    explain = per_hit("Cached_plan_profile_hit_explain_us", values)
    unique_build = per_hit("Cached_plan_profile_hit_unique_build_us", values)

    if "distinct_range" in label:
        if explain >= 0.15 or setup_aggr >= 0.10 or setup_post >= 0.10:
            return (
                "data-triggered-distinct-design",
                "DISTINCT range is high risk: investigate exact-shape aggregate setup/explain only after stable Linux regression",
            )
        return (
            "distinct-monitor",
            "DISTINCT range has hits; setup_distinct is not the main hotspot unless Linux data says otherwise",
        )
    if "order_range" in label:
        if range_build >= 0.45 or range_setup >= 0.25:
            return (
                "order-range-monitor",
                "ORDER range cost is mostly range build/setup; wait for stable Linux shape data before coding",
            )
    if "sum_range" in label or "simple_range" in label:
        if range_build >= 0.40 or range_setup >= 0.25:
            return (
                "range-low-risk-exhausted",
                "range build/setup remains visible, but prior micro-optimizations are near noise; prefer benchmark evidence",
            )
    if "point" in label or unique_build > 0:
        if hit_path < 0.20:
            return (
                "point-low-priority",
                "point/ref hit path is already low per-hit cost; do not prioritize point micro-optimizations",
            )
    return "observe", "no single actionable hotspot; collect longer profile if this case regresses"


def print_optimization_advice(items):
    print("## Optimization Advice")
    rows = []
    for path, values in items:
        bucket, advice = advice_for_case(path, values)
        if bucket == "ignore":
            continue
        rows.append((path, bucket, advice))
    if not rows:
        print("none\n")
        return
    print("| Case | Bucket | Advice |")
    print("|---|---|---|")
    for path, bucket, advice in rows:
        print(f"| {case_label(path)} | {bucket} | {advice} |")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Summarize raw/*.status_delta.tsv plan-cache profile files."
    )
    parser.add_argument("status_delta", nargs="+", help="status_delta.tsv file(s)")
    parser.add_argument("--top", type=int, default=5, help="top profile counters per case")
    args = parser.parse_args()

    items = []
    for path in args.status_delta:
        values = read_delta_file(path)
        if values:
            items.append((path, values))

    if not items:
        print("No status delta rows found.", file=sys.stderr)
        return 1

    print_case_summary(items, args.top)
    print_profile_hotspots(items, args.top)
    print_status_deltas(items)
    print_optimization_advice(items)
    return 0


if __name__ == "__main__":
    sys.exit(main())
