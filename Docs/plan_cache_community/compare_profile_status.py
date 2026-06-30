#!/usr/bin/env python3
"""Compare two sets of plan-cache profile/status delta files."""

import argparse
import os
import re
import sys


PROFILE_COUNTERS = {
    "Cached_plan_profile_hit_build_us",
    "Cached_plan_profile_hit_explain_us",
    "Cached_plan_profile_hit_path_us",
    "Cached_plan_profile_hit_unique_build_us",
    "Cached_plan_profile_hit_unique_read_us",
    "Cached_plan_profile_hit_unique_setup_us",
    "Cached_plan_profile_hit_ref_build_us",
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


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def read_delta_file(path):
    values = {}
    with open(path, newline="") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 4:
                values[parts[0]] = as_float(parts[3])
            elif len(parts) >= 2 and parts[0] != "Variable_name":
                values[parts[0]] = as_float(parts[1])
    return values


def case_label(path):
    name = os.path.basename(path)
    name = name.removesuffix(".status_delta.tsv")
    name = name.removesuffix(".tsv")
    return name


def normalized_case(path):
    label = case_label(path)
    label = re.sub(r"_t[0-9]+_", "_", label)
    label = re.sub(r"_t[0-9]+$", "", label)
    return label


def denominator_for(counter, values):
    if "_unique_" in counter:
        return values.get("Cached_plan_profile_hit_unique_count", 0.0)
    if "_ref_" in counter:
        return values.get("Cached_plan_profile_hit_ref_count", 0.0)
    if "_range_" in counter:
        return values.get("Cached_plan_profile_hit_range_count", 0.0)
    return values.get("Cached_plan_hits", 0.0)


def per_hit(counter, values):
    denom = denominator_for(counter, values)
    if denom <= 0:
        return 0.0
    return values.get(counter, 0.0) / denom


def merge_values(left, right):
    merged = dict(left)
    for key, value in right.items():
        merged[key] = merged.get(key, 0.0) + value
    return merged


def load_group(paths):
    cases = {}
    labels = {}
    for path in paths:
        values = read_delta_file(path)
        if not values:
            continue
        key = normalized_case(path)
        cases[key] = merge_values(cases.get(key, {}), values)
        labels.setdefault(key, case_label(path))
    return cases, labels


def delta_pct(before, after):
    if before == 0 and after == 0:
        return 0.0
    if before == 0:
        return 100.0
    return (after - before) * 100.0 / before


def comparison_rows(cases_a, cases_b):
    rows = []
    for key in sorted(set(cases_a) & set(cases_b)):
        values_a = cases_a[key]
        values_b = cases_b[key]
        hits_a = values_a.get("Cached_plan_hits", 0.0)
        hits_b = values_b.get("Cached_plan_hits", 0.0)
        invalid_a = values_a.get("Cached_plan_invalidations", 0.0)
        invalid_b = values_b.get("Cached_plan_invalidations", 0.0)
        for counter in PROFILE_COUNTERS:
            per_a = per_hit(counter, values_a)
            per_b = per_hit(counter, values_b)
            if per_a <= 0 and per_b <= 0:
                continue
            rows.append(
                (
                    key,
                    counter,
                    per_a,
                    per_b,
                    delta_pct(per_a, per_b),
                    hits_a,
                    hits_b,
                    invalid_a,
                    invalid_b,
                )
            )
    rows.sort(key=lambda row: (row[3], row[2]), reverse=True)
    return rows


def print_comparison(rows, label_a, label_b):
    print("## Profile Comparison")
    if not rows:
        print("none\n")
        return
    print(
        f"| Case | Counter | {label_a} us/hit | {label_b} us/hit | Delta % | {label_a} hits | {label_b} hits | Invalidations |"
    )
    print("|---|---|---:|---:|---:|---:|---:|---:|")
    for (
        key,
        counter,
        per_a,
        per_b,
        pct,
        hits_a,
        hits_b,
        invalid_a,
        invalid_b,
    ) in rows:
        print(
            "| {case} | {counter} | {per_a:.6f} | {per_b:.6f} | {pct:+.2f} | {hits_a:.0f} | {hits_b:.0f} | {invalid:.0f}/{invalid_b:.0f} |".format(
                case=key,
                counter=counter,
                per_a=per_a,
                per_b=per_b,
                pct=pct,
                hits_a=hits_a,
                hits_b=hits_b,
                invalid=invalid_a,
                invalid_b=invalid_b,
            )
        )
    print()


def print_candidate_signals(rows):
    print("## Candidate Signals")
    if not rows:
        print("none\n")
        return
    signals = []
    for key, counter, _per_a, per_b, _pct, _hits_a, _hits_b, invalid_a, invalid_b in rows:
        if invalid_a or invalid_b:
            signals.append((key, "invalid", "invalidations occurred; do not use this profile as optimization evidence"))
            continue
        if "distinct_range" in key and counter in {
            "Cached_plan_profile_hit_range_setup_post_us",
            "Cached_plan_profile_hit_range_setup_aggr_us",
            "Cached_plan_profile_hit_explain_us",
            "Cached_plan_profile_hit_range_setup_alloc_us",
        } and per_b >= 0.10:
            signals.append((key, "distinct-design-candidate", f"{counter} remains >= 0.10 us/hit in the second profile"))
        elif "point" in key and counter == "Cached_plan_profile_hit_path_us" and per_b < 0.20:
            signals.append((key, "point-low-priority", "point hit path remains below 0.20 us/hit"))
    if not signals:
        print("no actionable signal from compared rows\n")
        return
    print("| Case | Bucket | Reason |")
    print("|---|---|---|")
    seen = set()
    for key, bucket, reason in signals:
        ident = (key, bucket, reason)
        if ident in seen:
            continue
        seen.add(ident)
        print(f"| {key} | {bucket} | {reason} |")
    print()


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=(
            "Compare two profile/status delta sets. Usage: "
            "--label-a t1 A.status_delta.tsv ... --label-b t4 B.status_delta.tsv ..."
        )
    )
    parser.add_argument("--top", type=int, default=20, help="maximum comparison rows")
    known, remaining = parser.parse_known_args(argv)

    try:
        idx_a = remaining.index("--label-a")
        idx_b = remaining.index("--label-b")
    except ValueError:
        parser.error("both --label-a and --label-b are required")
    if idx_b <= idx_a + 2:
        parser.error("--label-a requires a label and at least one file")
    if idx_b + 2 > len(remaining):
        parser.error("--label-b requires a label and at least one file")

    label_a = remaining[idx_a + 1]
    files_a = remaining[idx_a + 2 : idx_b]
    label_b = remaining[idx_b + 1]
    files_b = remaining[idx_b + 2 :]
    if not files_a or not files_b:
        parser.error("both profile groups require at least one file")
    return known.top, label_a, files_a, label_b, files_b


def main(argv=None):
    top, label_a, files_a, label_b, files_b = parse_args(argv or sys.argv[1:])
    cases_a, _labels_a = load_group(files_a)
    cases_b, _labels_b = load_group(files_b)
    if not cases_a or not cases_b:
        print("No status delta rows found.", file=sys.stderr)
        return 1

    rows = comparison_rows(cases_a, cases_b)
    print_comparison(rows[:top], label_a, label_b)
    print_candidate_signals(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
