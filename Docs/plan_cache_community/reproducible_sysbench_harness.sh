#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=${ROOT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/build_plan_cache_release"}
OUT_DIR=${OUT_DIR:-"/tmp/mariadb-plan-cache-benchmark-runs/$(date +%Y%m%d-%H%M%S)"}
LUA_DIR=${LUA_DIR:-}

# shellcheck source=Docs/plan_cache_community/benchmark_env.sh
. "$ROOT_DIR/Docs/plan_cache_community/benchmark_env.sh"

TABLES=${TABLES:-8}
TABLE_SIZE=${TABLE_SIZE:-100000}
THREADS=${THREADS:-"1 2 4"}
WORKLOADS=${WORKLOADS:-"oltp_read_only oltp_point_select"}
REPEATS=${REPEATS:-5}
CALIBRATE_TIME=${CALIBRATE_TIME:-30}
WARMUP_TIME=${WARMUP_TIME:-60}
MEASURE_TIME=${MEASURE_TIME:-180}
RATE_FACTOR=${RATE_FACTOR:-0.65}
BUFFER_POOL_SIZE=${BUFFER_POOL_SIZE:-10G}
SERVER_CPUSET=${SERVER_CPUSET:-}
SYSBENCH_CPUSET=${SYSBENCH_CPUSET:-}
STRICT_CPUSET=${STRICT_CPUSET:-1}
FORMAL_CPUSET_REQUIRED=${FORMAL_CPUSET_REQUIRED:-0}
READ_ONLY_EXTRA_ARGS=${READ_ONLY_EXTRA_ARGS:---skip-trx=1}
PLAN_STATUS_INTERVAL=${PLAN_STATUS_INTERVAL:-1}
PREFLIGHT_ONLY=${PREFLIGHT_ONLY:-0}
COLLECT_PROFILE_STATUS=${COLLECT_PROFILE_STATUS:-0}

SERVER_EXTRA_OPTS=${SERVER_EXTRA_OPTS:-}
SYSBENCH_IGNORE_ERRORS=${SYSBENCH_IGNORE_ERRORS:-}

MYSQL="$BUILD_DIR/client/mariadb --no-defaults"
ADMIN="$BUILD_DIR/client/mariadb-admin --no-defaults"
BASE=""
DATADIR=""
SOCKET=""
PIDFILE=""
ERRLOG=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

resolve_lua_dir() {
  if [ -n "$LUA_DIR" ]; then
    test -f "$LUA_DIR/oltp_read_only.lua" ||
      die "LUA_DIR does not contain oltp_read_only.lua: $LUA_DIR"
    return
  fi

  for candidate in \
    /usr/share/sysbench \
    /usr/local/share/sysbench \
    /opt/homebrew/share/sysbench \
    /usr/share/doc/sysbench/tests/include/oltp_legacy
  do
    if [ -f "$candidate/oltp_read_only.lua" ]; then
      LUA_DIR=$candidate
      return
    fi
  done

  die "unable to find sysbench OLTP Lua scripts; set LUA_DIR explicitly"
}

require_release_build() {
  test -x "$BUILD_DIR/sql/mariadbd" || die "missing $BUILD_DIR/sql/mariadbd"
  test -x "$BUILD_DIR/client/mariadb" || die "missing $BUILD_DIR/client/mariadb"
  test -x "$BUILD_DIR/client/mariadb-admin" || die "missing $BUILD_DIR/client/mariadb-admin"
  test -x "$BUILD_DIR/scripts/mariadb-install-db" || die "missing $BUILD_DIR/scripts/mariadb-install-db"
  test -x "$BUILD_DIR/extra/my_print_defaults" || die "missing $BUILD_DIR/extra/my_print_defaults"

  grep -q '^CMAKE_BUILD_TYPE:STRING=Release$' "$BUILD_DIR/CMakeCache.txt" ||
    die "build is not CMAKE_BUILD_TYPE=Release"
  grep -q '^WITH_ASAN:BOOL=OFF$' "$BUILD_DIR/CMakeCache.txt" ||
    die "build has WITH_ASAN enabled"
}

task_prefix() {
  local cpuset=$1
  if [ -z "$cpuset" ]; then
    return 0
  fi
  if command -v numactl >/dev/null 2>&1; then
    printf 'numactl --physcpubind=%s ' "$cpuset"
  elif command -v taskset >/dev/null 2>&1; then
    printf 'taskset -c %s ' "$cpuset"
  else
    if [ "$STRICT_CPUSET" != "0" ]; then
      die "CPU set '$cpuset' requested but neither numactl nor taskset is available"
    fi
    return 0
  fi
}

preflight() {
  require_release_build
  resolve_lua_dir
  command -v sysbench >/dev/null 2>&1 || die "missing sysbench command"
  command -v python3 >/dev/null 2>&1 || die "missing python3 command"
  task_prefix "$SERVER_CPUSET" >/dev/null
  task_prefix "$SYSBENCH_CPUSET" >/dev/null
  local formal_cpuset_status
  if ! formal_cpuset_status=$(validate_formal_cpu_sets \
    "$FORMAL_CPUSET_REQUIRED" "$SERVER_CPUSET" "$SYSBENCH_CPUSET"); then
    echo "$formal_cpuset_status"
    die "formal CPU set validation failed"
  fi
  echo "$formal_cpuset_status"
  for workload in $WORKLOADS; do
    test -f "$LUA_DIR/$workload.lua" ||
      die "missing sysbench workload Lua: $LUA_DIR/$workload.lua"
  done

  echo "preflight_ok=1"
  echo "build_dir=$BUILD_DIR"
  echo "lua_dir=$LUA_DIR"
  echo "sysbench=$(sysbench --version)"
  echo "server_cpuset=${SERVER_CPUSET:-not-set}"
  echo "sysbench_cpuset=${SYSBENCH_CPUSET:-not-set}"
  echo "strict_cpuset=$STRICT_CPUSET"
  echo "formal_cpuset_required=$FORMAL_CPUSET_REQUIRED"
}

cleanup() {
  set +e
  if [ -n "${SOCKET:-}" ] && [ -S "$SOCKET" ]; then
    $ADMIN --socket="$SOCKET" -uroot shutdown >/dev/null 2>&1
  fi
  if [ -n "${PIDFILE:-}" ] && [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" >/dev/null 2>&1
  fi
  if [ -n "${BASE:-}" ]; then
    rm -rf "$BASE"
  fi
}

status_value() {
  local key=$1
  $MYSQL --socket="$SOCKET" -uroot -N -e "SHOW GLOBAL STATUS LIKE '$key'" |
    awk '{print $2}'
}

profile_status_snapshot() {
  local output=$1
  if [ "$COLLECT_PROFILE_STATUS" != "1" ]; then
    return
  fi
  $MYSQL --socket="$SOCKET" -uroot -N -e "SHOW GLOBAL STATUS" |
    awk '
      $1 ~ /^Cached_plan/ ||
      $1 ~ /^Handler_read_(key|next|rnd_next)$/ ||
      $1 ~ /^Created_tmp_(tables|disk_tables)$/ ||
      $1 ~ /^Table_open_cache_(hits|misses|overflows)$/ ||
      $1 ~ /^Opened_(tables|table_definitions)$/ ||
      $1 == "Threads_running" {
        print $1 "\t" $2
      }' > "$output"
}

profile_status_delta() {
  local before=$1
  local after=$2
  local output=$3
  if [ "$COLLECT_PROFILE_STATUS" != "1" ]; then
    return
  fi
  awk '
    NR == FNR {before[$1]=$2; next}
    {
      old=($1 in before ? before[$1] : 0)
      print $1 "\t" old "\t" $2 "\t" ($2 - old)
    }' "$before" "$after" > "$output"
}

cpu_sampler() {
  local pid=$1
  local output=$2
  while true; do
    ps -p "$pid" -o %cpu= 2>/dev/null || true
    sleep 1
  done > "$output"
}

plan_cache_status_sampler() {
  local output=$1
  printf "ts\tvariable\tvalue\n" > "$output"
  while true; do
    local ts
    ts=$(date +%s)
    $MYSQL --socket="$SOCKET" -uroot -N -e "SHOW GLOBAL STATUS LIKE 'Cached_plan%'" 2>/dev/null |
      awk -v ts="$ts" '{print ts "\t" $1 "\t" $2}' >> "$output"
    sleep "$PLAN_STATUS_INTERVAL"
  done
}

status_max_value() {
  local file=$1
  local key=$2
  awk -v key="$key" '$2 == key && $3 > max {max=$3} END {printf "%d", max}' "$file"
}

parse_tps() {
  awk '/transactions:/ {gsub(/[()]/, "", $3); print $3}' "$1"
}

parse_qps() {
  awk '/queries:/ {gsub(/[()]/, "", $3); print $3}' "$1"
}

parse_latency_avg() {
  awk '/^[[:space:]]*avg:/ {print $2}' "$1"
}

parse_latency_p95() {
  awk '/95th percentile:/ {print $3}' "$1"
}

workload_extra_args() {
  local workload=$1
  if [ "$workload" = "oltp_read_only" ]; then
    echo "$READ_ONLY_EXTRA_ARGS"
  fi
}

run_sysbench_case() {
  local phase=$1
  local workload=$2
  local threads=$3
  local mode=$4
  local seconds=$5
  local rate=${6:-0}
  local repeat=${7:-0}
  local result_file=$8
  local lua="$LUA_DIR/$workload.lua"
  local out="$OUT_DIR/raw/${phase}_${workload}_t${threads}_${mode}_r${repeat}.out"
  local cpu="$OUT_DIR/raw/${phase}_${workload}_t${threads}_${mode}_r${repeat}.cpu"
  local plan_status="$OUT_DIR/raw/${phase}_${workload}_t${threads}_${mode}_r${repeat}.plan_cache_status.tsv"
  local status_before="$OUT_DIR/raw/${phase}_${workload}_t${threads}_${mode}_r${repeat}.status_before.tsv"
  local status_after="$OUT_DIR/raw/${phase}_${workload}_t${threads}_${mode}_r${repeat}.status_after.tsv"
  local status_delta="$OUT_DIR/raw/${phase}_${workload}_t${threads}_${mode}_r${repeat}.status_delta.tsv"
  local server_pid

  server_pid=$(cat "$PIDFILE")
  $MYSQL --socket="$SOCKET" -uroot -e \
    "SET GLOBAL session_plan_cache=$mode; SET GLOBAL session_plan_cache_allow_change_ratio=0; SET GLOBAL session_plan_cache_profile=${COLLECT_PROFILE_STATUS}"

  local extra_args
  extra_args=$(workload_extra_args "$workload")
  local sysbench_prefix
  sysbench_prefix=$(task_prefix "$SYSBENCH_CPUSET")

  # shellcheck disable=SC2086
  $sysbench_prefix sysbench "$lua" "${COMMON[@]}" $extra_args \
    --threads="$threads" --time="$WARMUP_TIME" \
    --events=0 run >> "$OUT_DIR/raw/warmup.log" 2>&1

  local before_hits before_count before_invalid
  before_hits=$(status_value Cached_plan_hits)
  before_count=$(status_value Cached_plan_count)
  before_invalid=$(status_value Cached_plan_invalidations)
  profile_status_snapshot "$status_before"

  cpu_sampler "$server_pid" "$cpu" &
  local cpu_pid=$!
  plan_cache_status_sampler "$plan_status" &
  local plan_status_pid=$!
  if [ "$rate" != "0" ]; then
    # shellcheck disable=SC2086
    $sysbench_prefix sysbench "$lua" "${COMMON[@]}" $extra_args \
      --threads="$threads" --time="$seconds" --events=0 \
      --report-interval=30 --rate="$rate" run | tee "$out"
  else
    # shellcheck disable=SC2086
    $sysbench_prefix sysbench "$lua" "${COMMON[@]}" $extra_args \
      --threads="$threads" --time="$seconds" --events=0 \
      --report-interval=30 run | tee "$out"
  fi

  kill "$cpu_pid" >/dev/null 2>&1 || true
  kill "$plan_status_pid" >/dev/null 2>&1 || true
  wait "$cpu_pid" 2>/dev/null || true
  wait "$plan_status_pid" 2>/dev/null || true

  local after_hits after_count after_invalid
  after_hits=$(status_value Cached_plan_hits)
  after_count=$(status_value Cached_plan_count)
  after_invalid=$(status_value Cached_plan_invalidations)
  profile_status_snapshot "$status_after"
  profile_status_delta "$status_before" "$status_after" "$status_delta"

  local tps qps avg p95 cpu_avg cpu_max
  tps=$(parse_tps "$out")
  qps=$(parse_qps "$out")
  avg=$(parse_latency_avg "$out")
  p95=$(parse_latency_p95 "$out")
  cpu_avg=$(awk 'NF {sum+=$1; n++} END {if(n) printf "%.2f", sum/n; else printf "0.00"}' "$cpu")
  cpu_max=$(awk 'NF && $1>max {max=$1} END {printf "%.2f", max}' "$cpu")
  local live_count_max
  live_count_max=$(status_max_value "$plan_status" Cached_plan_count)

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$phase" "$repeat" "$workload" "$threads" "$mode" "$rate" "$tps" "$qps" \
    "$avg" "$p95" "$((after_hits-before_hits))" \
    "$((after_count-before_count))" "$((after_invalid-before_invalid))" \
    "$cpu_avg" "$cpu_max" "$live_count_max" >> "$result_file"
}

calibrate_rate() {
  local workload=$1
  local threads=$2

  run_sysbench_case calibrate "$workload" "$threads" OFF "$CALIBRATE_TIME" 0 0 "$OUT_DIR/calibration.tsv" >/dev/null
  run_sysbench_case calibrate "$workload" "$threads" ON "$CALIBRATE_TIME" 0 0 "$OUT_DIR/calibration.tsv" >/dev/null

  local off_tps on_tps
  off_tps=$(tail -n 2 "$OUT_DIR/calibration.tsv" | head -n 1 | awk -F '\t' '{print $7}')
  on_tps=$(tail -n 1 "$OUT_DIR/calibration.tsv" | awk -F '\t' '{print $7}')

  awk -v a="$off_tps" -v b="$on_tps" -v f="$RATE_FACTOR" \
    'BEGIN {m=(a < b ? a : b); r=int(m*f); if (r < 1) r=1; print r}'
}

write_summary() {
  local input=$1
  local output=$2
  python3 - "$input" "$output" <<'PY'
import csv
import math
import statistics
import sys

input_path, output_path = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(input_path), delimiter="\t"))

def f(row, key):
    try:
        return float(row[key])
    except (TypeError, ValueError):
        return 0.0

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

groups = {}
for row in rows:
    groups.setdefault((row["phase"], row["workload"], row["threads"], row["rate"]), {}).setdefault(row["mode"], []).append(row)

fields = [
    "phase", "workload", "threads", "rate", "repeats",
    "off_tps_median", "on_tps_median", "tps_delta_pct",
    "off_qps_median", "on_qps_median", "qps_delta_pct",
    "off_qps_p25", "off_qps_p75", "off_qps_cv_pct",
    "on_qps_p25", "on_qps_p75", "on_qps_cv_pct",
    "off_cpu_median", "on_cpu_median", "cpu_delta_pct",
    "off_cpu_per_kqps", "on_cpu_per_kqps", "cpu_per_kqps_delta_pct",
    "on_hit_delta_median", "on_invalid_delta_sum", "on_live_count_max_median",
]

with open(output_path, "w", newline="") as out:
    writer = csv.DictWriter(out, fieldnames=fields, delimiter="\t")
    writer.writeheader()
    for phase, workload, threads, rate in sorted(groups, key=lambda x: (x[0], x[1], int(x[2]), int(float(x[3])))):
        off = groups[(phase, workload, threads, rate)].get("OFF", [])
        on = groups[(phase, workload, threads, rate)].get("ON", [])
        if not off or not on:
            continue
        off_tps = [f(r, "tps") for r in off]
        on_tps = [f(r, "tps") for r in on]
        off_qps = [f(r, "qps") for r in off]
        on_qps = [f(r, "qps") for r in on]
        off_cpu = [f(r, "cpu_avg_pct") for r in off]
        on_cpu = [f(r, "cpu_avg_pct") for r in on]
        off_tps_med, on_tps_med = median(off_tps), median(on_tps)
        off_qps_med, on_qps_med = median(off_qps), median(on_qps)
        off_cpu_med, on_cpu_med = median(off_cpu), median(on_cpu)
        off_cpu_per = off_cpu_med / off_qps_med * 1000.0 if off_qps_med else 0.0
        on_cpu_per = on_cpu_med / on_qps_med * 1000.0 if on_qps_med else 0.0
        writer.writerow({
            "phase": phase,
            "workload": workload,
            "threads": threads,
            "rate": rate,
            "repeats": min(len(off), len(on)),
            "off_tps_median": f"{off_tps_med:.2f}",
            "on_tps_median": f"{on_tps_med:.2f}",
            "tps_delta_pct": f"{((on_tps_med / off_tps_med - 1.0) * 100.0) if off_tps_med else 0.0:.2f}",
            "off_qps_median": f"{off_qps_med:.2f}",
            "on_qps_median": f"{on_qps_med:.2f}",
            "qps_delta_pct": f"{((on_qps_med / off_qps_med - 1.0) * 100.0) if off_qps_med else 0.0:.2f}",
            "off_qps_p25": f"{percentile(off_qps, 0.25):.2f}",
            "off_qps_p75": f"{percentile(off_qps, 0.75):.2f}",
            "off_qps_cv_pct": f"{cv_pct(off_qps):.2f}",
            "on_qps_p25": f"{percentile(on_qps, 0.25):.2f}",
            "on_qps_p75": f"{percentile(on_qps, 0.75):.2f}",
            "on_qps_cv_pct": f"{cv_pct(on_qps):.2f}",
            "off_cpu_median": f"{off_cpu_med:.2f}",
            "on_cpu_median": f"{on_cpu_med:.2f}",
            "cpu_delta_pct": f"{((on_cpu_med / off_cpu_med - 1.0) * 100.0) if off_cpu_med else 0.0:.2f}",
            "off_cpu_per_kqps": f"{off_cpu_per:.4f}",
            "on_cpu_per_kqps": f"{on_cpu_per:.4f}",
            "cpu_per_kqps_delta_pct": f"{((on_cpu_per / off_cpu_per - 1.0) * 100.0) if off_cpu_per else 0.0:.2f}",
            "on_hit_delta_median": f"{median([f(r, 'hit_delta') for r in on]):.0f}",
            "on_invalid_delta_sum": f"{sum(f(r, 'invalid_delta') for r in on):.0f}",
            "on_live_count_max_median": f"{median([f(r, 'live_count_max') for r in on]):.0f}",
        })
PY
}

write_analysis() {
  local summary=$1
  local output=$2
  local analyzer="$ROOT_DIR/Docs/plan_cache_community/analyze_sysbench_summary.py"
  if [ ! -x "$analyzer" ]; then
    echo "WARNING: missing analyzer: $analyzer" >&2
    return
  fi
  if ! "$analyzer" "$summary" > "$output"; then
    echo "WARNING: benchmark summary has invalid evidence rows; see $output" >&2
  fi
}

write_profile_status_analysis() {
  if [ "$COLLECT_PROFILE_STATUS" != "1" ]; then
    return
  fi
  local analyzer="$ROOT_DIR/Docs/plan_cache_community/analyze_profile_status.py"
  if [ ! -x "$analyzer" ]; then
    echo "WARNING: missing analyzer: $analyzer" >&2
    return
  fi
  local files=("$OUT_DIR"/raw/*.status_delta.tsv)
  if [ ! -e "${files[0]}" ]; then
    echo "WARNING: no status_delta.tsv files found under $OUT_DIR/raw" >&2
    return
  fi
  "$analyzer" "${files[@]}" > "$OUT_DIR/profile_status_analysis.md"
}

write_final_plan_cache_status() {
  $MYSQL --socket="$SOCKET" -uroot -N -e "SHOW GLOBAL STATUS LIKE 'Cached_plan%'" \
    > "$OUT_DIR/final_plan_cache_status.tsv"
}

write_error_log_summary() {
  if [ -f "$ERRLOG" ]; then
    grep -Ei 'warn|error|fail|crash|abort' "$ERRLOG" \
      > "$OUT_DIR/mariadbd_error_summary.txt" || true
  fi
}

write_run_manifest() {
  {
    echo "artifact_dir=$OUT_DIR"
    echo "source_head=$(git -C "$ROOT_DIR" rev-parse HEAD)"
    echo "build_dir=$BUILD_DIR"
    echo "build_type=$(awk -F= '/^CMAKE_BUILD_TYPE:/{print $2}' "$BUILD_DIR/CMakeCache.txt")"
    echo "with_asan=$(awk -F= '/^WITH_ASAN:/{print $2}' "$BUILD_DIR/CMakeCache.txt")"
    echo "mariadbd=$BUILD_DIR/sql/mariadbd"
    echo "mariadbd_version=$("$BUILD_DIR/sql/mariadbd" --version)"
    echo "server_cpuset=${SERVER_CPUSET:-not-set}"
    echo "sysbench_cpuset=${SYSBENCH_CPUSET:-not-set}"
    echo "formal_cpuset_required=$FORMAL_CPUSET_REQUIRED"
    echo "server_options=--no-defaults --datadir=<tmp> --socket=<tmp> --port=$port --bind-address=127.0.0.1 --skip-log-bin --innodb-buffer-pool-size=$BUFFER_POOL_SIZE --innodb-flush-log-at-trx-commit=2 --innodb-doublewrite=0 --performance-schema=OFF --table-open-cache=8192 --table-definition-cache=8192 --max-connections=512 ${SERVER_EXTRA_OPTS:-}"
    echo "lua_dir=$LUA_DIR"
    echo "sysbench_version=$(sysbench --version)"
    echo "sysbench_common=${COMMON[*]}"
    echo "workloads=$WORKLOADS"
    echo "read_only_extra_args=$READ_ONLY_EXTRA_ARGS"
    echo "tables=$TABLES"
    echo "table_size=$TABLE_SIZE"
    echo "threads=$THREADS"
    echo "calibrate_time=$CALIBRATE_TIME"
    echo "warmup_time=$WARMUP_TIME"
    echo "measure_time=$MEASURE_TIME"
    echo "repeats=$REPEATS"
    echo "rate_factor=$RATE_FACTOR"
    echo "collect_profile_status=$COLLECT_PROFILE_STATUS"
    echo "sysbench_ignore_errors=${SYSBENCH_IGNORE_ERRORS:-not-set}"
  } > "$OUT_DIR/run_manifest.txt"
}

main() {
  if [ "$PREFLIGHT_ONLY" = "1" ]; then
    preflight
    return
  fi

  preflight >/dev/null
  mkdir -p "$OUT_DIR/raw"

  BASE="/tmp/mariadb-plan-cache-repro-$(date +%Y%m%d-%H%M%S)-$$"
  DATADIR="$BASE/data"
  SOCKET="$BASE/mariadb.sock"
  PIDFILE="$BASE/mariadbd.pid"
  ERRLOG="$OUT_DIR/mariadbd.err"
  local port=$((36000 + ($$ % 1000)))

  trap cleanup EXIT
  mkdir -p "$BASE" "$DATADIR"

  {
    echo "root_dir=$ROOT_DIR"
    echo "build_dir=$BUILD_DIR"
    echo "out_dir=$OUT_DIR"
    echo "head=$(git -C "$ROOT_DIR" rev-parse HEAD)"
    echo "version=$("$BUILD_DIR/sql/mariadbd" --version)"
    echo "sysbench=$(sysbench --version)"
    echo "lua_dir=$LUA_DIR"
    echo "buffer_pool_size=$BUFFER_POOL_SIZE"
    echo "read_only_extra_args=$READ_ONLY_EXTRA_ARGS"
    echo "plan_status_interval=$PLAN_STATUS_INTERVAL"
    echo "collect_profile_status=$COLLECT_PROFILE_STATUS"
    echo "server_cpuset=${SERVER_CPUSET:-not-set}"
    echo "sysbench_cpuset=${SYSBENCH_CPUSET:-not-set}"
    echo "strict_cpuset=$STRICT_CPUSET"
    echo "formal_cpuset_required=$FORMAL_CPUSET_REQUIRED"
    validate_formal_cpu_sets "$FORMAL_CPUSET_REQUIRED" \
      "$SERVER_CPUSET" "$SYSBENCH_CPUSET" || true
    echo "server_extra_opts=${SERVER_EXTRA_OPTS:-not-set}"
    echo "sysbench_ignore_errors=${SYSBENCH_IGNORE_ERRORS:-not-set}"
    echo "preflight_only=$PREFLIGHT_ONLY"
    echo "taskset=$(command -v taskset || true)"
    echo "numactl=$(command -v numactl || true)"
    echo "cmake_build_type=$(awk -F= '/^CMAKE_BUILD_TYPE:/{print $2}' "$BUILD_DIR/CMakeCache.txt")"
    echo "with_asan=$(awk -F= '/^WITH_ASAN:/{print $2}' "$BUILD_DIR/CMakeCache.txt")"
    uname -a
    write_benchmark_host_env
  } > "$OUT_DIR/environment.txt"

  "$BUILD_DIR/scripts/mariadb-install-db" \
    --no-defaults \
    --force \
    --srcdir="$ROOT_DIR" \
    --builddir="$BUILD_DIR" \
    --datadir="$DATADIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db > "$OUT_DIR/install-db.log" 2>&1

  local server_prefix
  server_prefix=$(task_prefix "$SERVER_CPUSET")
  # shellcheck disable=SC2086
  $server_prefix "$BUILD_DIR/sql/mariadbd" \
    --no-defaults \
    --datadir="$DATADIR" \
    --socket="$SOCKET" \
    --port="$port" \
    --bind-address=127.0.0.1 \
    --pid-file="$PIDFILE" \
    --log-error="$ERRLOG" \
    --skip-log-bin \
    --innodb-buffer-pool-size="$BUFFER_POOL_SIZE" \
    --innodb-flush-log-at-trx-commit=2 \
    --innodb-doublewrite=0 \
    --performance-schema=OFF \
    --table-open-cache=8192 \
    --table-definition-cache=8192 \
    --max-connections=512 \
    $SERVER_EXTRA_OPTS > "$OUT_DIR/mariadbd.stdout" 2>&1 &

  for _ in $(seq 1 60); do
    if $ADMIN --socket="$SOCKET" -uroot ping >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  $ADMIN --socket="$SOCKET" -uroot ping >/dev/null 2>&1 ||
    die "server failed to start; see $ERRLOG"

  $MYSQL --socket="$SOCKET" -uroot -e "CREATE DATABASE sbtest"
  $MYSQL --socket="$SOCKET" -uroot -e "SET GLOBAL query_cache_type=OFF" >/dev/null 2>&1 || true

  COMMON=(--mysql-socket="$SOCKET" --mysql-user=root --mysql-db=sbtest
    --db-driver=mysql --db-ps-mode=auto
    --mysql-storage-engine=innodb --tables="$TABLES" --table-size="$TABLE_SIZE"
    --rand-type=uniform)
  if [ -n "$SYSBENCH_IGNORE_ERRORS" ]; then
    COMMON+=(--mysql-ignore-errors="$SYSBENCH_IGNORE_ERRORS")
  fi
  write_run_manifest

  sysbench "$LUA_DIR/oltp_read_only.lua" "${COMMON[@]}" cleanup >/dev/null 2>&1 || true
  sysbench "$LUA_DIR/oltp_read_only.lua" "${COMMON[@]}" prepare | tee "$OUT_DIR/prepare.log"

  printf "phase\trepeat\tworkload\tthreads\tmode\trate\ttps\tqps\tlat_avg_ms\tlat_p95_ms\thit_delta\tcount_delta\tinvalid_delta\tcpu_avg_pct\tcpu_max_pct\tlive_count_max\n" \
    > "$OUT_DIR/calibration.tsv"
  cp "$OUT_DIR/calibration.tsv" "$OUT_DIR/fixed_rate.tsv"
  cp "$OUT_DIR/calibration.tsv" "$OUT_DIR/closed_loop.tsv"

  for workload in $WORKLOADS; do
    for threads in $THREADS; do
      local rate
      rate=$(calibrate_rate "$workload" "$threads")
      echo "$workload threads=$threads fixed event rate=$rate"

      for repeat in $(seq 1 "$REPEATS"); do
        if [ $((repeat % 2)) -eq 0 ]; then
          run_sysbench_case fixed "$workload" "$threads" ON "$MEASURE_TIME" "$rate" "$repeat" "$OUT_DIR/fixed_rate.tsv"
          run_sysbench_case fixed "$workload" "$threads" OFF "$MEASURE_TIME" "$rate" "$repeat" "$OUT_DIR/fixed_rate.tsv"
        else
          run_sysbench_case fixed "$workload" "$threads" OFF "$MEASURE_TIME" "$rate" "$repeat" "$OUT_DIR/fixed_rate.tsv"
          run_sysbench_case fixed "$workload" "$threads" ON "$MEASURE_TIME" "$rate" "$repeat" "$OUT_DIR/fixed_rate.tsv"
        fi
      done

      for repeat in $(seq 1 "$REPEATS"); do
        if [ $((repeat % 2)) -eq 0 ]; then
          run_sysbench_case closed "$workload" "$threads" ON "$MEASURE_TIME" 0 "$repeat" "$OUT_DIR/closed_loop.tsv"
          run_sysbench_case closed "$workload" "$threads" OFF "$MEASURE_TIME" 0 "$repeat" "$OUT_DIR/closed_loop.tsv"
        else
          run_sysbench_case closed "$workload" "$threads" OFF "$MEASURE_TIME" 0 "$repeat" "$OUT_DIR/closed_loop.tsv"
          run_sysbench_case closed "$workload" "$threads" ON "$MEASURE_TIME" 0 "$repeat" "$OUT_DIR/closed_loop.tsv"
        fi
      done
    done
  done

  write_summary "$OUT_DIR/fixed_rate.tsv" "$OUT_DIR/fixed_rate_summary.tsv"
  write_summary "$OUT_DIR/closed_loop.tsv" "$OUT_DIR/closed_loop_summary.tsv"
  write_analysis "$OUT_DIR/fixed_rate_summary.tsv" "$OUT_DIR/fixed_rate_analysis.md"
  write_analysis "$OUT_DIR/closed_loop_summary.tsv" "$OUT_DIR/closed_loop_analysis.md"
  write_profile_status_analysis
  write_final_plan_cache_status
  write_error_log_summary
  echo "results: $OUT_DIR"
}

main "$@"
