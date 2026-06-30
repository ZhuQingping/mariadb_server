#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=${ROOT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/build_plan_cache_release"}
ARTIFACT_ROOT=${ARTIFACT_ROOT:-/tmp}
SUITE_MODE=${SUITE_MODE:-preflight}

TABLES=${TABLES:-250}
TABLE_SIZE=${TABLE_SIZE:-25000}
BUFFER_POOL_SIZE=${BUFFER_POOL_SIZE:-10G}
PREWARM_TIME=${PREWARM_TIME:-120}
RUN_TIME=${RUN_TIME:-300}
REPEATS=${REPEATS:-5}
THREADS=${THREADS:-"1 2 4 8 16"}
SERVER_CPUSET=${SERVER_CPUSET:-}
SYSBENCH_CPUSET=${SYSBENCH_CPUSET:-}
STRICT_CPUSET=${STRICT_CPUSET:-1}
FORMAL_CPUSET_REQUIRED=${FORMAL_CPUSET_REQUIRED:-}
REPORT_INTERVAL=${REPORT_INTERVAL:-1}
PERCENTILE=${PERCENTILE:-95}
COLLECT_PROFILE_STATUS=${COLLECT_PROFILE_STATUS:-0}
SERVER_EXTRA_OPTS=${SERVER_EXTRA_OPTS:-}
SYSBENCH_IGNORE_ERRORS=${SYSBENCH_IGNORE_ERRORS:-}
READ_ONLY_EXTRA_ARGS=${READ_ONLY_EXTRA_ARGS:---skip-trx=1}
RATE_FACTOR=${RATE_FACTOR:-0.65}
CALIBRATE_TIME=${CALIBRATE_TIME:-30}
PRIMARY_GATE_THREADS=${PRIMARY_GATE_THREADS-"1 2 4 8"}
PRIMARY_GATE_MIN_POSITIVE_REPEATS=${PRIMARY_GATE_MIN_POSITIVE_REPEATS:-4}

primary_gate_min_positive_repeats() {
  if [ "$PRIMARY_GATE_MIN_POSITIVE_REPEATS" -gt "$REPEATS" ]; then
    echo "$REPEATS"
  else
    echo "$PRIMARY_GATE_MIN_POSITIVE_REPEATS"
  fi
}

formal_cpuset_required() {
  if [ -n "$FORMAL_CPUSET_REQUIRED" ]; then
    echo "$FORMAL_CPUSET_REQUIRED"
    return
  fi
  case "$SUITE_MODE" in
    preflight|primary|shapes|point|fixed|formal|value) echo 1 ;;
    *) echo 0 ;;
  esac
}

write_artifact_summary() {
  local out_dir=$1
  "$ROOT_DIR/Docs/plan_cache_community/summarize_benchmark_artifacts.py" \
    "$out_dir" > "$out_dir/benchmark_artifact_summary.md"
}

run_formal_mode() {
  local formal_root="$ARTIFACT_ROOT/plan-cache-formal-$(date +%Y%m%d-%H%M%S)"
  local suite="$ROOT_DIR/Docs/plan_cache_community/run_sysbench_benchmark_suite.sh"
  mkdir -p "$formal_root"

  ARTIFACT_ROOT="$formal_root" SUITE_MODE=preflight "$suite"
  ARTIFACT_ROOT="$formal_root" SUITE_MODE=primary "$suite"
  ARTIFACT_ROOT="$formal_root" SUITE_MODE=shapes "$suite"
  ARTIFACT_ROOT="$formal_root" SUITE_MODE=fixed "$suite"

  "$ROOT_DIR/Docs/plan_cache_community/summarize_benchmark_artifacts.py" \
    "$formal_root"/plan-cache-primary-* \
    "$formal_root"/plan-cache-shapes-* \
    "$formal_root"/plan-cache-fixed-* \
    > "$formal_root/benchmark_artifact_summary.md"
  echo "formal_results: $formal_root"
}

run_value_mode() {
  local value_root="$ARTIFACT_ROOT/plan-cache-value-$(date +%Y%m%d-%H%M%S)"
  local suite="$ROOT_DIR/Docs/plan_cache_community/run_sysbench_benchmark_suite.sh"
  local shape_threads="${SHAPE_THREADS:-1 2 4 8}"
  mkdir -p "$value_root"

  ARTIFACT_ROOT="$value_root" SUITE_MODE=preflight "$suite"
  ARTIFACT_ROOT="$value_root" SUITE_MODE=primary "$suite"
  ARTIFACT_ROOT="$value_root" SUITE_MODE=shapes \
    SHAPE_THREADS="$shape_threads" READ_ONLY_SHAPES=distinct_range "$suite"

  "$ROOT_DIR/Docs/plan_cache_community/summarize_benchmark_artifacts.py" \
    "$value_root"/plan-cache-primary-* \
    "$value_root"/plan-cache-shapes-* \
    > "$value_root/benchmark_artifact_summary.md"
  echo "value_results: $value_root"
}

run_in_memory() {
  local out_prefix=$1
  local out_dir="$ARTIFACT_ROOT/${out_prefix}-$(date +%Y%m%d-%H%M%S)"
  local formal_required
  formal_required=$(formal_cpuset_required)
  ROOT_DIR="$ROOT_DIR" \
  BUILD_DIR="$BUILD_DIR" \
  OUT_DIR="$out_dir" \
  TABLES="$TABLES" \
  TABLE_SIZE="$TABLE_SIZE" \
  THREADS="$THREADS" \
  WORKLOADS="$WORKLOADS" \
  READ_ONLY_SHAPES="${READ_ONLY_SHAPES:-}" \
  BUFFER_POOL_SIZE="$BUFFER_POOL_SIZE" \
  PREWARM_TIME="$PREWARM_TIME" \
  RUN_TIME="$RUN_TIME" \
  REPEATS="$REPEATS" \
  SERVER_CPUSET="$SERVER_CPUSET" \
  SYSBENCH_CPUSET="$SYSBENCH_CPUSET" \
  STRICT_CPUSET="$STRICT_CPUSET" \
  FORMAL_CPUSET_REQUIRED="$formal_required" \
  REPORT_INTERVAL="$REPORT_INTERVAL" \
  PERCENTILE="$PERCENTILE" \
  COLLECT_PROFILE_STATUS="$COLLECT_PROFILE_STATUS" \
  SERVER_EXTRA_OPTS="$SERVER_EXTRA_OPTS" \
  SYSBENCH_IGNORE_ERRORS="$SYSBENCH_IGNORE_ERRORS" \
  READ_ONLY_EXTRA_ARGS="$READ_ONLY_EXTRA_ARGS" \
  "$ROOT_DIR/Docs/plan_cache_community/in_memory_sysbench_harness.sh"
  local gate_rc=0
  if [ "$SUITE_MODE" = "primary" ] && [ -n "$PRIMARY_GATE_THREADS" ]; then
    local min_positive_repeats
    min_positive_repeats=$(primary_gate_min_positive_repeats)
    set +e
    "$ROOT_DIR/Docs/plan_cache_community/analyze_sysbench_summary.py" \
      --require-primary-threads "$PRIMARY_GATE_THREADS" \
      --detail-results "$out_dir/results.tsv" \
      --min-positive-repeats "$min_positive_repeats" \
      "$out_dir/summary.tsv" > "$out_dir/primary_gate_analysis.md"
    gate_rc=$?
    set -e
  fi
  write_artifact_summary "$out_dir"
  return "$gate_rc"
}

case "$SUITE_MODE" in
  preflight)
    formal_required=$(formal_cpuset_required)
    ROOT_DIR="$ROOT_DIR" \
    BUILD_DIR="$BUILD_DIR" \
    WORKLOADS="oltp_read_only" \
    SERVER_CPUSET="$SERVER_CPUSET" \
    SYSBENCH_CPUSET="$SYSBENCH_CPUSET" \
    STRICT_CPUSET="$STRICT_CPUSET" \
    FORMAL_CPUSET_REQUIRED="$formal_required" \
    REPORT_INTERVAL="$REPORT_INTERVAL" \
    PERCENTILE="$PERCENTILE" \
    COLLECT_PROFILE_STATUS="$COLLECT_PROFILE_STATUS" \
    SERVER_EXTRA_OPTS="$SERVER_EXTRA_OPTS" \
    SYSBENCH_IGNORE_ERRORS="$SYSBENCH_IGNORE_ERRORS" \
    READ_ONLY_EXTRA_ARGS="$READ_ONLY_EXTRA_ARGS" \
    PREFLIGHT_ONLY=1 \
    "$ROOT_DIR/Docs/plan_cache_community/in_memory_sysbench_harness.sh"
    ;;
  primary)
    THREADS="$THREADS" WORKLOADS="oltp_read_only" \
      run_in_memory "plan-cache-primary"
    ;;
  shapes)
    THREADS=${SHAPE_THREADS:-"1 2 4 8"} \
    WORKLOADS="oltp_read_only" \
    READ_ONLY_SHAPES=${READ_ONLY_SHAPES:-"distinct_range sum_range order_range simple_range point"} \
      run_in_memory "plan-cache-shapes"
    ;;
  point)
    THREADS="$THREADS" WORKLOADS="oltp_point_select" \
      run_in_memory "plan-cache-point-select"
    ;;
  fixed)
    formal_required=$(formal_cpuset_required)
    out_dir="$ARTIFACT_ROOT/plan-cache-fixed-$(date +%Y%m%d-%H%M%S)"
    ROOT_DIR="$ROOT_DIR" \
    BUILD_DIR="$BUILD_DIR" \
    OUT_DIR="$out_dir" \
    TABLES="$TABLES" \
    TABLE_SIZE="$TABLE_SIZE" \
    BUFFER_POOL_SIZE="$BUFFER_POOL_SIZE" \
    WARMUP_TIME="$PREWARM_TIME" \
    MEASURE_TIME="$RUN_TIME" \
    REPEATS="$REPEATS" \
    THREADS="$THREADS" \
    WORKLOADS=${WORKLOADS:-"oltp_read_only"} \
    SERVER_CPUSET="$SERVER_CPUSET" \
    SYSBENCH_CPUSET="$SYSBENCH_CPUSET" \
    STRICT_CPUSET="$STRICT_CPUSET" \
    FORMAL_CPUSET_REQUIRED="$formal_required" \
    COLLECT_PROFILE_STATUS="$COLLECT_PROFILE_STATUS" \
    SERVER_EXTRA_OPTS="$SERVER_EXTRA_OPTS" \
    SYSBENCH_IGNORE_ERRORS="$SYSBENCH_IGNORE_ERRORS" \
    READ_ONLY_EXTRA_ARGS="$READ_ONLY_EXTRA_ARGS" \
    RATE_FACTOR="$RATE_FACTOR" \
    CALIBRATE_TIME="$CALIBRATE_TIME" \
    "$ROOT_DIR/Docs/plan_cache_community/reproducible_sysbench_harness.sh"
    write_artifact_summary "$out_dir"
    ;;
  formal)
    run_formal_mode
    ;;
  value)
    run_value_mode
    ;;
  diagnostic)
    ROOT_DIR="$ROOT_DIR" \
    BUILD_DIR="$BUILD_DIR" \
    OUT_DIR="$ARTIFACT_ROOT/plan-cache-linearity-$(date +%Y%m%d-%H%M%S)" \
    TABLES="$TABLES" \
    TABLE_SIZE="$TABLE_SIZE" \
    BUFFER_POOL_SIZE="$BUFFER_POOL_SIZE" \
    PREWARM_TIME="$PREWARM_TIME" \
    RUN_TIME="$RUN_TIME" \
    THREADS="$THREADS" \
    WORKLOADS=${WORKLOADS:-"oltp_point_select oltp_read_only"} \
    SERVER_EXTRA_OPTS="$SERVER_EXTRA_OPTS" \
    SYSBENCH_IGNORE_ERRORS="$SYSBENCH_IGNORE_ERRORS" \
    "$ROOT_DIR/Docs/plan_cache_community/linearity_diagnostic_harness.sh"
    ;;
  *)
    echo "Unknown SUITE_MODE=$SUITE_MODE" >&2
    echo "Use one of: preflight, primary, shapes, point, fixed, formal, value, diagnostic" >&2
    echo "Fast value path: SUITE_MODE=value" >&2
    exit 1
    ;;
esac
