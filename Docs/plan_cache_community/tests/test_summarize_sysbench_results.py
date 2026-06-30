#!/usr/bin/env python3

import csv
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Docs/plan_cache_community/summarize_sysbench_results.py"


def write_tsv(path, rows):
    fields = [
        "repeat",
        "workload",
        "threads",
        "mode",
        "tps",
        "qps",
        "lat_avg_ms",
        "lat_p95_ms",
        "hit_delta",
        "count_delta",
        "invalid_delta",
        "cpu_avg_pct",
        "cpu_max_pct",
        "live_count_max",
        "valid",
        "sample_warning",
        "elapsed_sec",
        "expected_sec",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def read_summary(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def base_row(repeat, mode, qps, valid="1", warning="", elapsed="30.0"):
    return {
        "repeat": repeat,
        "workload": "oltp_read_only:distinct_range",
        "threads": "4",
        "mode": mode,
        "tps": qps,
        "qps": qps,
        "lat_avg_ms": "0.10",
        "lat_p95_ms": "0.00",
        "hit_delta": "1000" if mode == "ON" else "0",
        "count_delta": "0",
        "invalid_delta": "0",
        "cpu_avg_pct": "100.0",
        "cpu_max_pct": "110.0",
        "live_count_max": "64" if mode == "ON" else "0",
        "valid": valid,
        "sample_warning": warning,
        "elapsed_sec": elapsed,
        "expected_sec": "30",
    }


def test_invalid_elapsed_sample_is_excluded_from_summary():
    with tempfile.TemporaryDirectory() as tmp:
        results = Path(tmp) / "results.tsv"
        summary = Path(tmp) / "summary.tsv"
        write_tsv(
            results,
            [
                base_row("1", "OFF", "10000"),
                base_row("1", "ON", "20000"),
                base_row("2", "OFF", "11000"),
                base_row("2", "ON", "100", "0", "elapsed_over_limit", "923.7"),
            ],
        )

        subprocess.run([sys.executable, str(SCRIPT), str(results), str(summary)], check=True)

        rows = read_summary(summary)
        assert len(rows) == 1
        row = rows[0]
        assert row["repeats"] == "1"
        assert row["invalid_samples"] == "1"
        assert row["off_qps_median"] == "10000.00"
        assert row["on_qps_median"] == "20000.00"
        assert row["qps_delta_pct"] == "100.00"


if __name__ == "__main__":
    test_invalid_elapsed_sample_is_excluded_from_summary()
