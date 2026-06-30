#!/usr/bin/env python3

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Docs/plan_cache_community/run_sysbench_benchmark_suite.sh"


def test_value_mode_runs_primary_and_distinct_range_only():
    text = SCRIPT.read_text()

    assert "run_value_mode()" in text
    assert "SUITE_MODE=value" in text
    assert "READ_ONLY_SHAPES=distinct_range" in text
    assert "plan-cache-value-" in text


if __name__ == "__main__":
    test_value_mode_runs_primary_and_distinct_range_only()
