#!/usr/bin/env python3
"""Create a compact Markdown review summary from benchmark artifact dirs."""

import argparse
import csv
from pathlib import Path


def read_kv(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def read_status(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            values[parts[0]] = parts[1]
    return values


def read_tsv(path):
    if not path.exists():
        return []
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def existing_paths(directory, names):
    paths = []
    for name in names:
        path = directory / name
        if path.exists():
            paths.append(path)
    return paths


def as_float(row, key):
    try:
        return float(row.get(key, "0") or "0")
    except ValueError:
        return 0.0


def expand_cpu_set(value):
    cpus = set()
    if not value or value == "not-set":
        return None
    for part in value.split(","):
        if not part:
            return None
        if "-" in part:
            start, end = part.split("-", 1)
            if not start.isdigit() or not end.isdigit():
                return None
            start_i = int(start)
            end_i = int(end)
            if start_i > end_i:
                return None
            cpus.update(range(start_i, end_i + 1))
        else:
            if not part.isdigit():
                return None
            cpus.add(int(part))
    return cpus


def artifact_label(directory, manifest):
    return manifest.get("artifact_dir") or str(directory)


def print_manifest(directory, manifest):
    print(f"### {artifact_label(directory, manifest)}")
    print()
    fields = [
        ("HEAD", "source_head"),
        ("Build", "build_type"),
        ("ASAN", "with_asan"),
        ("Server CPU set", "server_cpuset"),
        ("Sysbench CPU set", "sysbench_cpuset"),
        ("Formal CPU-set gate", "formal_cpuset_required"),
        ("Tables", "tables"),
        ("Table size", "table_size"),
        ("Threads", "threads"),
        ("Run time", "run_time"),
        ("Measure time", "measure_time"),
        ("Repeats", "repeats"),
        ("Workloads", "workloads"),
        ("Read-only shapes", "read_only_shapes"),
    ]
    print("| Field | Value |")
    print("|---|---|")
    for label, key in fields:
        value = manifest.get(key)
        if value:
            print(f"| {label} | `{value}` |")
    print()


def detail_key(row):
    return (
        row.get("phase", ""),
        row.get("workload", ""),
        row.get("threads", ""),
        row.get("rate", ""),
        row.get("repeat", ""),
    )


def case_key(row):
    return (
        row.get("phase", ""),
        row.get("workload", ""),
        row.get("threads", ""),
        row.get("rate", ""),
    )


def case_label(key):
    phase, workload, threads, rate = key
    label = f"{workload}:t{threads}"
    if phase:
        label = f"{phase}:{label}:rate{rate}"
    return label


def repeat_signals(detail_rows):
    by_repeat = {}
    for row in detail_rows:
        by_repeat.setdefault(detail_key(row), {})[row.get("mode", "")] = row

    signals = {}
    for modes in by_repeat.values():
        off = modes.get("OFF")
        on = modes.get("ON")
        if not off or not on:
            continue
        off_qps = as_float(off, "qps")
        on_qps = as_float(on, "qps")
        off_cpu_per = (
            as_float(off, "cpu_avg_pct") / off_qps * 1000.0 if off_qps else 0.0
        )
        on_cpu_per = (
            as_float(on, "cpu_avg_pct") / on_qps * 1000.0 if on_qps else 0.0
        )
        signals.setdefault(case_key(on), []).append(
            {
                "qps_positive": on_qps > off_qps,
                "cpu_positive": on_cpu_per < off_cpu_per,
            }
        )
    return signals


def print_repeat_signals(title, detail_rows):
    signals = repeat_signals(detail_rows)
    if not signals:
        return
    print(f"#### {title} repeat-level signals")
    print()
    print("| Case | Repeats | QPS positive | CPU/kQPS positive |")
    print("|---|---:|---:|---:|")
    for key, rows in sorted(signals.items(), key=lambda item: case_label(item[0])):
        print(
            "| {case} | {repeats} | {qps_pos} | {cpu_pos} |".format(
                case=case_label(key),
                repeats=len(rows),
                qps_pos=sum(1 for item in rows if item["qps_positive"]),
                cpu_pos=sum(1 for item in rows if item["cpu_positive"]),
            )
        )
    print()


def print_summary_rows(title, summary_rows):
    print(f"#### {title}")
    print()
    if not summary_rows:
        print("No summary TSV found.")
        print()
        return
    print("| Case | Repeats | Invalid samples | OFF QPS | ON QPS | QPS delta % | CPU/kQPS delta % | Hits | Invalidations | Live count |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in summary_rows:
        phase = row.get("phase", "")
        rate = row.get("rate", "")
        workload = row.get("workload", "")
        threads = row.get("threads", "")
        case = f"{workload}:t{threads}"
        if phase:
            case = f"{phase}:{case}:rate{rate}"
        print(
            "| {case} | {repeats} | {invalid_samples} | {off_qps} | {on_qps} | {qps_delta} | {cpu_delta} | {hits} | {invalid} | {live} |".format(
                case=case,
                repeats=row.get("repeats", ""),
                invalid_samples=row.get("invalid_samples", "0"),
                off_qps=row.get("off_qps_median", ""),
                on_qps=row.get("on_qps_median", ""),
                qps_delta=row.get("qps_delta_pct", ""),
                cpu_delta=row.get("cpu_per_kqps_delta_pct", ""),
                hits=row.get("on_hit_delta_median", ""),
                invalid=row.get("on_invalid_delta_sum", ""),
                live=row.get("on_live_count_max_median", ""),
            )
        )
    print()


def print_gate_summary(directory):
    gate = directory / "primary_gate_analysis.md"
    if not gate.exists():
        print("Primary gate: not present")
        print()
        return []
    text = gate.read_text(errors="replace")
    failed = [
        line.strip("- ")
        for line in text.splitlines()
        if line.startswith("- ") and "missing" in line.lower()
        or line.startswith("- ") and "required" in line.lower()
    ]
    if failed:
        print("Primary gate: FAIL")
        for item in failed:
            print(f"- {item}")
    else:
        print("Primary gate: PASS")
    print()
    return failed


def print_final_status(directory):
    status = read_status(directory / "final_plan_cache_status.tsv")
    if not status:
        print("Final plan-cache status: missing")
        print()
        return
    print(
        "Final plan-cache status: "
        f"count={status.get('Cached_plan_count', 'missing')}, "
        f"hits={status.get('Cached_plan_hits', 'missing')}, "
        f"invalidations={status.get('Cached_plan_invalidations', 'missing')}"
    )
    print()


def print_error_summary(directory):
    path = directory / "mariadbd_error_summary.txt"
    if not path.exists():
        print("Error-log summary: missing")
    elif path.stat().st_size == 0:
        print("Error-log summary: empty")
    else:
        print("Error-log summary: non-empty, inspect artifact before publishing")
    print()


def collect_manifest_signals(manifest):
    signals = []
    formal = manifest.get("formal_cpuset_required", "")
    server = manifest.get("server_cpuset", "")
    sysbench = manifest.get("sysbench_cpuset", "")

    if formal != "1":
        signals.append("Formal CPU-set gate was not enabled for this run.")

    server_set = expand_cpu_set(server)
    sysbench_set = expand_cpu_set(sysbench)
    if server_set is None:
        signals.append("Server CPU set is missing or invalid.")
    if sysbench_set is None:
        signals.append("Sysbench CPU set is missing or invalid.")
    if server_set is not None and sysbench_set is not None and server_set & sysbench_set:
        signals.append("Server and sysbench CPU sets overlap.")

    if manifest.get("build_type") != "Release":
        signals.append("Build type is not Release.")
    if manifest.get("with_asan") != "OFF":
        signals.append("ASAN is not OFF.")

    return signals


def collect_review_signals(manifest, summary_rows, detail_rows, gate_failures, status, error_path):
    signals = []
    signals.extend(collect_manifest_signals(manifest))
    if gate_failures:
        signals.append("Primary evidence gate failed; inspect required thread coverage before publishing.")

    for row in summary_rows:
        phase = row.get("phase", "")
        workload = row.get("workload", "")
        threads = row.get("threads", "")
        rate = row.get("rate", "")
        label = f"{workload}:t{threads}"
        if phase:
            label = f"{phase}:{label}:rate{rate}"
        if as_float(row, "on_invalid_delta_sum") != 0:
            signals.append(f"{label}: plan-cache invalidations are non-zero.")
        if as_float(row, "invalid_samples") > 0:
            signals.append(f"{label}: invalid benchmark samples were excluded.")
        if as_float(row, "on_hit_delta_median") <= 0:
            signals.append(f"{label}: missing ON hit evidence.")
        if as_float(row, "on_live_count_max_median") <= 0:
            signals.append(f"{label}: missing live Cached_plan_count evidence.")
        if as_float(row, "qps_delta_pct") < 0:
            signals.append(f"{label}: median QPS regressed.")
        if as_float(row, "cpu_per_kqps_delta_pct") > 0:
            signals.append(f"{label}: CPU/kQPS regressed.")

    for title, rows in detail_rows:
        for key, values in repeat_signals(rows).items():
            repeats = len(values)
            if repeats == 0:
                continue
            qps_positive = sum(1 for item in values if item["qps_positive"])
            cpu_positive = sum(1 for item in values if item["cpu_positive"])
            label = case_label(key)
            if qps_positive < repeats:
                signals.append(
                    f"{title}:{label}: QPS positive in {qps_positive}/{repeats} repeats."
                )
            if cpu_positive < repeats:
                signals.append(
                    f"{title}:{label}: CPU/kQPS positive in {cpu_positive}/{repeats} repeats."
                )

    if status:
        if status.get("Cached_plan_count") not in (None, "0"):
            signals.append("Final Cached_plan_count did not return to zero.")
        if status.get("Cached_plan_invalidations") not in (None, "0"):
            signals.append("Final Cached_plan_invalidations is non-zero.")
    else:
        signals.append("Final plan-cache status artifact is missing.")

    if not error_path.exists():
        signals.append("Error-log summary artifact is missing.")
    elif error_path.stat().st_size != 0:
        signals.append("Error-log summary is non-empty.")

    return signals


def summary_case_label(row):
    phase = row.get("phase", "")
    workload = row.get("workload", "")
    threads = row.get("threads", "")
    rate = row.get("rate", "")
    label = f"{workload}:t{threads}"
    if phase:
        label = f"{phase}:{label}:rate{rate}"
    return label


def collect_opportunity_signals(summary_rows, limit):
    valid_rows = [
        row
        for row in summary_rows
        if as_float(row, "on_hit_delta_median") > 0
        and as_float(row, "on_invalid_delta_sum") == 0
    ]
    qps_gain = sorted(
        [row for row in valid_rows if as_float(row, "qps_delta_pct") > 0],
        key=lambda row: as_float(row, "qps_delta_pct"),
        reverse=True,
    )
    cpu_gain = sorted(
        [row for row in valid_rows if as_float(row, "cpu_per_kqps_delta_pct") < 0],
        key=lambda row: as_float(row, "cpu_per_kqps_delta_pct"),
    )
    weakest = sorted(
        valid_rows,
        key=lambda row: (
            as_float(row, "qps_delta_pct"),
            -as_float(row, "cpu_per_kqps_delta_pct"),
        ),
    )
    return qps_gain[:limit], cpu_gain[:limit], weakest[:limit]


def print_opportunity_table(title, rows):
    print(f"##### {title}")
    print()
    if not rows:
        print("none")
        print()
        return
    print("| Case | QPS delta % | CPU/kQPS delta % | Hits | Live count |")
    print("|---|---:|---:|---:|---:|")
    for row in rows:
        print(
            "| {case} | {qps:.2f} | {cpu:.2f} | {hits:.0f} | {live:.0f} |".format(
                case=summary_case_label(row),
                qps=as_float(row, "qps_delta_pct"),
                cpu=as_float(row, "cpu_per_kqps_delta_pct"),
                hits=as_float(row, "on_hit_delta_median"),
                live=as_float(row, "on_live_count_max_median"),
            )
        )
    print()


def print_opportunity_signals(summary_rows, limit):
    print("#### Opportunity Signals")
    print()
    qps_gain, cpu_gain, weakest = collect_opportunity_signals(summary_rows, limit)
    print_opportunity_table("Strongest QPS Gains", qps_gain)
    print_opportunity_table("Best CPU/kQPS Improvements", cpu_gain)
    print_opportunity_table("Weakest Valid Cases", weakest)


def print_review_signals(signals):
    print("#### Review Signals")
    print()
    if not signals:
        print("No immediate risk signals detected in summarized artifacts.")
        print()
        return
    for item in signals:
        print(f"- {item}")
    print()


def has_positive_primary(summary_rows):
    primary = [
        row
        for row in summary_rows
        if row.get("workload") == "oltp_read_only"
        and not row.get("phase", "")
        and as_float(row, "qps_delta_pct") > 0
        and as_float(row, "on_hit_delta_median") > 0
        and as_float(row, "on_invalid_delta_sum") == 0
    ]
    return bool(primary)


def has_shape(summary_rows, shape):
    return any(
        shape in row.get("workload", "")
        and as_float(row, "qps_delta_pct") > 0
        and as_float(row, "on_hit_delta_median") > 0
        and as_float(row, "on_invalid_delta_sum") == 0
        for row in summary_rows
    )


def has_fixed_efficiency(summary_rows):
    return any(
        row.get("phase") == "fixed"
        and as_float(row, "cpu_per_kqps_delta_pct") < 0
        and as_float(row, "on_hit_delta_median") > 0
        and as_float(row, "on_invalid_delta_sum") == 0
        for row in summary_rows
    )


def collect_next_actions(summary_rows, review_signals):
    actions = []
    if review_signals:
        actions.append(
            "Resolve Review Signals before using this artifact for a community-facing claim."
        )
    elif has_positive_primary(summary_rows):
        actions.append(
            "Primary read-only evidence is positive; update the benchmark report with artifact tables and raw directory path."
        )
    else:
        actions.append(
            "Primary read-only evidence is absent or weak; run/inspect the primary suite before making a value claim."
        )

    if has_shape(summary_rows, "distinct_range"):
        actions.append(
            "Use distinct_range as the first attribution case for where plan cache saves optimizer work."
        )
    else:
        actions.append(
            "Run shape attribution if primary evidence is positive but the strongest template is not identified."
        )

    if has_fixed_efficiency(summary_rows):
        actions.append(
            "Use fixed-rate CPU/kQPS data as efficiency evidence when closed-loop QPS is noisy."
        )

    weak_rows = [
        row
        for row in summary_rows
        if as_float(row, "on_hit_delta_median") > 0
        and as_float(row, "on_invalid_delta_sum") == 0
        and (
            as_float(row, "qps_delta_pct") < 0
            or as_float(row, "cpu_per_kqps_delta_pct") > 0
        )
    ]
    if weak_rows:
        labels = ", ".join(summary_case_label(row) for row in weak_rows[:3])
        actions.append(
            f"Treat weak valid cases as the next profiling queue before changing production code: {labels}."
        )

    return actions


def print_next_actions(actions):
    print("#### Next Actions")
    print()
    for item in actions:
        print(f"- {item}")
    print()


def summarize(directory, opportunity_limit):
    manifest = read_kv(directory / "run_manifest.txt")
    print_manifest(directory, manifest)
    summary_paths = existing_paths(
        directory,
        ["summary.tsv", "fixed_rate_summary.tsv", "closed_loop_summary.tsv"],
    )
    all_summary_rows = []
    if summary_paths:
        for summary_path in summary_paths:
            rows = read_tsv(summary_path)
            all_summary_rows.extend(rows)
            print_summary_rows(summary_path.name, rows)
    else:
        print_summary_rows("summary", [])
    detail_sets = []
    for detail_path in existing_paths(
        directory,
        ["results.tsv", "fixed_rate.tsv", "closed_loop.tsv"],
    ):
        rows = read_tsv(detail_path)
        detail_sets.append((detail_path.name, rows))
        print_repeat_signals(detail_path.name, rows)
    gate_failures = print_gate_summary(directory)
    print_final_status(directory)
    print_error_summary(directory)
    print_opportunity_signals(all_summary_rows, opportunity_limit)
    review_signals = collect_review_signals(
        manifest,
        all_summary_rows,
        detail_sets,
        gate_failures,
        read_status(directory / "final_plan_cache_status.tsv"),
        directory / "mariadbd_error_summary.txt",
    )
    print_next_actions(collect_next_actions(all_summary_rows, review_signals))
    print_review_signals(
        review_signals
    )
    return len(review_signals)


def main():
    parser = argparse.ArgumentParser(
        description="Summarize plan-cache benchmark artifact directories."
    )
    parser.add_argument("artifact_dir", nargs="+", type=Path)
    parser.add_argument(
        "--opportunity-limit",
        type=int,
        default=5,
        help="number of rows to show in each opportunity table",
    )
    parser.add_argument(
        "--fail-on-review-signals",
        action="store_true",
        help="exit non-zero if any summarized artifact has Review Signals",
    )
    args = parser.parse_args()

    print("# Plan Cache Benchmark Artifact Summary")
    print()
    review_signal_count = 0
    for directory in args.artifact_dir:
        review_signal_count += summarize(directory, args.opportunity_limit)
    if args.fail_on_review_signals and review_signal_count:
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
