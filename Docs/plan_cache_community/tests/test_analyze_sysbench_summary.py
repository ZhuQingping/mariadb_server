#!/usr/bin/env python3

import csv
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Docs/plan_cache_community/analyze_sysbench_summary.py"


def test_invalid_samples_make_summary_invalid():
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
    row = {
        "workload": "oltp_read_only",
        "threads": "1",
        "repeats": "4",
        "invalid_samples": "1",
        "off_tps_median": "100",
        "on_tps_median": "130",
        "tps_delta_pct": "30",
        "off_qps_median": "100",
        "on_qps_median": "130",
        "qps_delta_pct": "30",
        "off_qps_p25": "100",
        "off_qps_p75": "100",
        "off_qps_cv_pct": "0",
        "on_qps_p25": "130",
        "on_qps_p75": "130",
        "on_qps_cv_pct": "0",
        "off_cpu_median": "100",
        "on_cpu_median": "90",
        "cpu_delta_pct": "-10",
        "off_cpu_per_kqps": "1000",
        "on_cpu_per_kqps": "692.3",
        "cpu_per_kqps_delta_pct": "-30.77",
        "on_hit_delta_median": "1000",
        "on_invalid_delta_sum": "0",
        "on_live_count_max_median": "64",
    }
    with tempfile.TemporaryDirectory() as tmp:
        summary = Path(tmp) / "summary.tsv"
        with summary.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
            writer.writeheader()
            writer.writerow(row)

        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(summary)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        assert result.returncode == 2
        assert "Invalid Evidence Rows" in result.stdout
        assert "invalid benchmark samples" in result.stdout


if __name__ == "__main__":
    test_invalid_samples_make_summary_invalid()
