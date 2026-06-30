#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=${ROOT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/build_plan_cache_release"}
OUT_DIR=${OUT_DIR:-"/tmp/mariadb-plan-cache-in-memory/$(date +%Y%m%d-%H%M%S)"}
LUA_DIR=${LUA_DIR:-}

# shellcheck source=Docs/plan_cache_community/benchmark_env.sh
. "$ROOT_DIR/Docs/plan_cache_community/benchmark_env.sh"

TABLES=${TABLES:-250}
TABLE_SIZE=${TABLE_SIZE:-25000}
THREADS=${THREADS:-"1 2 4 8 16"}
WORKLOADS=${WORKLOADS:-"oltp_point_select oltp_read_only"}
RUN_TIME=${RUN_TIME:-600}
PREWARM_TIME=${PREWARM_TIME:-120}
REPORT_INTERVAL=${REPORT_INTERVAL:-1}
PERCENTILE=${PERCENTILE:-95}
REPEATS=${REPEATS:-1}
MODE_ORDER_ODD=${MODE_ORDER_ODD:-"OFF ON"}
MODE_ORDER_EVEN=${MODE_ORDER_EVEN:-"ON OFF"}
BUFFER_POOL_SIZE=${BUFFER_POOL_SIZE:-10G}
SERVER_CPUSET=${SERVER_CPUSET:-}
SYSBENCH_CPUSET=${SYSBENCH_CPUSET:-}
STRICT_CPUSET=${STRICT_CPUSET:-1}
FORMAL_CPUSET_REQUIRED=${FORMAL_CPUSET_REQUIRED:-0}
SERVER_EXTRA_OPTS=${SERVER_EXTRA_OPTS:-}
READ_ONLY_EXTRA_ARGS=${READ_ONLY_EXTRA_ARGS:---skip-trx=1}
READ_ONLY_SHAPES=${READ_ONLY_SHAPES:-}
PLAN_STATUS_INTERVAL=${PLAN_STATUS_INTERVAL:-1}
SYSBENCH_IGNORE_ERRORS=${SYSBENCH_IGNORE_ERRORS:-}
PREFLIGHT_ONLY=${PREFLIGHT_ONLY:-0}
COLLECT_PROFILE_STATUS=${COLLECT_PROFILE_STATUS:-0}

MYSQL="$BUILD_DIR/client/mariadb --no-defaults"
ADMIN="$BUILD_DIR/client/mariadb-admin --no-defaults"
BASE=""
DATADIR=""
SOCKET=""
PIDFILE=""
ERRLOG=""
COMMON=()

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

parse_field() {
  local file=$1
  local pattern=$2
  awk -v pat="$pattern" '$0 ~ pat {gsub(/[()]/, "", $3); print $3}' "$file"
}

parse_latency_avg() {
  awk '/^[[:space:]]*avg:/ {print $2}' "$1"
}

parse_latency_p95() {
  awk '/95th percentile:/ {print $3}' "$1"
}

parse_total_time() {
  awk '/^[[:space:]]*total time:/ {gsub(/s$/, "", $3); print $3}' "$1"
}

sample_validity() {
  local out=$1
  local expected=$2
  local elapsed=$3
  local tps=$4
  local qps=$5
  local max_factor=${MAX_SYSBENCH_ELAPSED_FACTOR:-1.5}
  python3 - "$out" "$expected" "$elapsed" "$tps" "$qps" "$max_factor" <<'PY'
import sys

_out, expected, elapsed, tps, qps, max_factor = sys.argv[1:]

def as_float(value):
    try:
        return float(value or 0)
    except ValueError:
        return 0.0

expected = as_float(expected)
elapsed = as_float(elapsed)
tps = as_float(tps)
qps = as_float(qps)
max_factor = as_float(max_factor) or 1.5
warnings = []

if tps <= 0 or qps <= 0:
    warnings.append("missing_tps_or_qps")
if expected > 0 and elapsed > expected * max_factor:
    warnings.append("elapsed_over_limit")

print("0\t" + ",".join(warnings) if warnings else "1\t")
PY
}

sysbench_args_for_workload() {
  local workload=$1
  if [ "$workload" = "oltp_read_only" ]; then
    echo "read-only"
  fi
}

read_only_args_for_shape() {
  local shape=$1
  case "$shape" in
    ""|"all")
      echo "$READ_ONLY_EXTRA_ARGS"
      ;;
    "point")
      echo "--skip-trx=1 --point-selects=1 --simple-ranges=0 --sum-ranges=0 --order-ranges=0 --distinct-ranges=0"
      ;;
    "simple_range")
      echo "--skip-trx=1 --point-selects=0 --simple-ranges=1 --sum-ranges=0 --order-ranges=0 --distinct-ranges=0"
      ;;
    "sum_range")
      echo "--skip-trx=1 --point-selects=0 --simple-ranges=0 --sum-ranges=1 --order-ranges=0 --distinct-ranges=0"
      ;;
    "order_range")
      echo "--skip-trx=1 --point-selects=0 --simple-ranges=0 --sum-ranges=0 --order-ranges=1 --distinct-ranges=0"
      ;;
    "distinct_range")
      echo "--skip-trx=1 --point-selects=0 --simple-ranges=0 --sum-ranges=0 --order-ranges=0 --distinct-ranges=1"
      ;;
    *)
      die "unknown READ_ONLY_SHAPES entry: $shape"
      ;;
  esac
}

run_case() {
  local repeat=$1
  local workload=$2
  local threads=$3
  local mode=$4
  local read_only_shape=${5:-}
  local lua="$LUA_DIR/$workload.lua"
  local workload_label="$workload"
  local file_label="$workload"
  if [ -n "$read_only_shape" ]; then
    workload_label="${workload}:${read_only_shape}"
    file_label="${workload}_${read_only_shape}"
  fi
  local out="$OUT_DIR/raw/${file_label}_t${threads}_${mode}_r${repeat}.out"
  local cpu="$OUT_DIR/raw/${file_label}_t${threads}_${mode}_r${repeat}.cpu"
  local plan_status="$OUT_DIR/raw/${file_label}_t${threads}_${mode}_r${repeat}.plan_cache_status.tsv"
  local status_before="$OUT_DIR/raw/${file_label}_t${threads}_${mode}_r${repeat}.status_before.tsv"
  local status_after="$OUT_DIR/raw/${file_label}_t${threads}_${mode}_r${repeat}.status_after.tsv"
  local status_delta="$OUT_DIR/raw/${file_label}_t${threads}_${mode}_r${repeat}.status_delta.tsv"
  local server_pid
  server_pid=$(cat "$PIDFILE")

  $MYSQL --socket="$SOCKET" -uroot -e \
    "SET GLOBAL session_plan_cache=$mode; SET GLOBAL session_plan_cache_allow_change_ratio=0; SET GLOBAL session_plan_cache_profile=${COLLECT_PROFILE_STATUS}"

  local before_hits before_count before_invalid
  before_hits=$(status_value Cached_plan_hits)
  before_count=$(status_value Cached_plan_count)
  before_invalid=$(status_value Cached_plan_invalidations)
  profile_status_snapshot "$status_before"

  cpu_sampler "$server_pid" "$cpu" &
  local cpu_pid=$!
  plan_cache_status_sampler "$plan_status" &
  local plan_status_pid=$!

  local prefix
  prefix=$(task_prefix "$SYSBENCH_CPUSET")
  if [ "$(sysbench_args_for_workload "$workload")" = "read-only" ]; then
    local read_only_args
    read_only_args=$(read_only_args_for_shape "$read_only_shape")
    if [ -n "$prefix" ]; then
      # shellcheck disable=SC2086
      $prefix sysbench "$lua" "${COMMON[@]}" $read_only_args \
        --threads="$threads" --time="$RUN_TIME" --events=0 \
        --percentile="$PERCENTILE" --report-interval="$REPORT_INTERVAL" run |
        tee "$out"
    else
      # shellcheck disable=SC2086
      sysbench "$lua" "${COMMON[@]}" $read_only_args \
        --threads="$threads" --time="$RUN_TIME" --events=0 \
        --percentile="$PERCENTILE" --report-interval="$REPORT_INTERVAL" run |
        tee "$out"
    fi
  else
    if [ -n "$prefix" ]; then
      # shellcheck disable=SC2086
      $prefix sysbench "$lua" "${COMMON[@]}" \
        --threads="$threads" --time="$RUN_TIME" --events=0 \
        --percentile="$PERCENTILE" --report-interval="$REPORT_INTERVAL" run |
        tee "$out"
    else
      sysbench "$lua" "${COMMON[@]}" \
        --threads="$threads" --time="$RUN_TIME" --events=0 \
        --percentile="$PERCENTILE" --report-interval="$REPORT_INTERVAL" run |
        tee "$out"
    fi
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

  local tps qps lat_avg lat_p95 elapsed valid_warning valid sample_warning cpu_avg cpu_max
  tps=$(parse_field "$out" "transactions:")
  qps=$(parse_field "$out" "queries:")
  lat_avg=$(parse_latency_avg "$out")
  lat_p95=$(parse_latency_p95 "$out")
  elapsed=$(parse_total_time "$out")
  valid_warning=$(sample_validity "$out" "$RUN_TIME" "$elapsed" "$tps" "$qps")
  valid=${valid_warning%%$'\t'*}
  sample_warning=${valid_warning#*$'\t'}
  cpu_avg=$(awk 'NF {sum+=$1; n++} END {if(n) printf "%.2f", sum/n; else printf "0.00"}' "$cpu")
  cpu_max=$(awk 'NF && $1>max {max=$1} END {printf "%.2f", max}' "$cpu")
  local live_count_max
  live_count_max=$(status_max_value "$plan_status" Cached_plan_count)

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$repeat" "$workload_label" "$threads" "$mode" "$tps" "$qps" \
    "$lat_avg" "$lat_p95" "$((after_hits-before_hits))" \
    "$((after_count-before_count))" "$((after_invalid-before_invalid))" \
    "$cpu_avg" "$cpu_max" "$live_count_max" "$valid" "$sample_warning" \
    "${elapsed:-0}" "$RUN_TIME" >> "$OUT_DIR/results.tsv"
}

prewarm() {
  echo "Prewarming InnoDB buffer pool"
  # shellcheck disable=SC2086
  sysbench "$LUA_DIR/oltp_read_only.lua" "${COMMON[@]}" \
    $READ_ONLY_EXTRA_ARGS --threads=16 --time="$PREWARM_TIME" --events=0 \
    --percentile="$PERCENTILE" --report-interval=10 run |
    tee "$OUT_DIR/prewarm.log"
}

write_summary() {
  "$ROOT_DIR/Docs/plan_cache_community/summarize_sysbench_results.py" \
    "$OUT_DIR/results.tsv" "$OUT_DIR/summary.tsv"
}

write_analysis() {
  local analyzer="$ROOT_DIR/Docs/plan_cache_community/analyze_sysbench_summary.py"
  if [ ! -x "$analyzer" ]; then
    echo "WARNING: missing analyzer: $analyzer" >&2
    return
  fi
  if ! "$analyzer" "$OUT_DIR/summary.tsv" > "$OUT_DIR/summary_analysis.md"; then
    echo "WARNING: benchmark summary has invalid evidence rows; see $OUT_DIR/summary_analysis.md" >&2
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
    echo "server_options=--no-defaults --datadir=<tmp> --socket=<tmp> --port=$port --bind-address=127.0.0.1 --skip-log-bin --innodb-buffer-pool-size=$BUFFER_POOL_SIZE --innodb-buffer-pool-load-at-startup=OFF --innodb-flush-log-at-trx-commit=2 --innodb-doublewrite=0 --query-cache-type=0 --query-cache-size=0 --performance-schema=OFF --table-open-cache=8192 --table-definition-cache=8192 --max-connections=1024 --max-prepared-stmt-count=1048576 ${SERVER_EXTRA_OPTS:-}"
    echo "lua_dir=$LUA_DIR"
    echo "sysbench_version=$(sysbench --version)"
    echo "sysbench_common=${COMMON[*]}"
    echo "workloads=$WORKLOADS"
    echo "read_only_shapes=${READ_ONLY_SHAPES:-not-set}"
    echo "read_only_extra_args=$READ_ONLY_EXTRA_ARGS"
    echo "tables=$TABLES"
    echo "table_size=$TABLE_SIZE"
    echo "threads=$THREADS"
    echo "prewarm_time=$PREWARM_TIME"
    echo "run_time=$RUN_TIME"
    echo "repeats=$REPEATS"
    echo "mode_order_odd=$MODE_ORDER_ODD"
    echo "mode_order_even=$MODE_ORDER_EVEN"
    echo "report_interval=$REPORT_INTERVAL"
    echo "percentile=$PERCENTILE"
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

  BASE="/tmp/mariadb-plan-cache-in-memory-$(date +%Y%m%d-%H%M%S)-$$"
  DATADIR="$BASE/data"
  SOCKET="$BASE/mariadb.sock"
  PIDFILE="$BASE/mariadbd.pid"
  ERRLOG="$OUT_DIR/mariadbd.err"
  local port=$((37000 + ($$ % 1000)))
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
    echo "tables=$TABLES"
    echo "table_size=$TABLE_SIZE"
    echo "threads=$THREADS"
    echo "workloads=$WORKLOADS"
    echo "run_time=$RUN_TIME"
    echo "prewarm_time=$PREWARM_TIME"
    echo "read_only_extra_args=$READ_ONLY_EXTRA_ARGS"
    echo "read_only_shapes=${READ_ONLY_SHAPES:-not-set}"
    echo "plan_status_interval=$PLAN_STATUS_INTERVAL"
    echo "collect_profile_status=$COLLECT_PROFILE_STATUS"
    echo "mode_order_odd=$MODE_ORDER_ODD"
    echo "mode_order_even=$MODE_ORDER_EVEN"
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
    --no-defaults --force --srcdir="$ROOT_DIR" --builddir="$BUILD_DIR" \
    --datadir="$DATADIR" --auth-root-authentication-method=normal \
    --skip-test-db > "$OUT_DIR/install-db.log" 2>&1

  local server_prefix
  server_prefix=$(task_prefix "$SERVER_CPUSET")
  if [ -n "$server_prefix" ]; then
    # shellcheck disable=SC2086
    $server_prefix "$BUILD_DIR/sql/mariadbd" \
      --no-defaults --datadir="$DATADIR" --socket="$SOCKET" --port="$port" \
      --bind-address=127.0.0.1 --pid-file="$PIDFILE" --log-error="$ERRLOG" \
      --skip-log-bin --innodb-buffer-pool-size="$BUFFER_POOL_SIZE" \
      --innodb-buffer-pool-load-at-startup=OFF \
      --innodb-flush-log-at-trx-commit=2 --innodb-doublewrite=0 \
      --query-cache-type=0 --query-cache-size=0 \
      --performance-schema=OFF --table-open-cache=8192 \
      --table-definition-cache=8192 --max-connections=1024 \
      --max-prepared-stmt-count=1048576 \
      $SERVER_EXTRA_OPTS > "$OUT_DIR/mariadbd.stdout" 2>&1 &
  else
    "$BUILD_DIR/sql/mariadbd" \
      --no-defaults --datadir="$DATADIR" --socket="$SOCKET" --port="$port" \
      --bind-address=127.0.0.1 --pid-file="$PIDFILE" --log-error="$ERRLOG" \
      --skip-log-bin --innodb-buffer-pool-size="$BUFFER_POOL_SIZE" \
      --innodb-buffer-pool-load-at-startup=OFF \
      --innodb-flush-log-at-trx-commit=2 --innodb-doublewrite=0 \
      --query-cache-type=0 --query-cache-size=0 \
      --performance-schema=OFF --table-open-cache=8192 \
      --table-definition-cache=8192 --max-connections=1024 \
      --max-prepared-stmt-count=1048576 \
      $SERVER_EXTRA_OPTS > "$OUT_DIR/mariadbd.stdout" 2>&1 &
  fi

  for _ in $(seq 1 90); do
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
  sysbench "$LUA_DIR/oltp_read_only.lua" "${COMMON[@]}" prepare |
    tee "$OUT_DIR/prepare.log"
  prewarm

  printf "repeat\tworkload\tthreads\tmode\ttps\tqps\tlat_avg_ms\tlat_p95_ms\thit_delta\tcount_delta\tinvalid_delta\tcpu_avg_pct\tcpu_max_pct\tlive_count_max\tvalid\tsample_warning\telapsed_sec\texpected_sec\n" \
    > "$OUT_DIR/results.tsv"

  for repeat in $(seq 1 "$REPEATS"); do
    if [ $((repeat % 2)) -eq 0 ]; then
      mode_order="$MODE_ORDER_EVEN"
    else
      mode_order="$MODE_ORDER_ODD"
    fi
    for workload in $WORKLOADS; do
      if [ "$workload" = "oltp_read_only" ] && [ -n "$READ_ONLY_SHAPES" ]; then
        for shape in $READ_ONLY_SHAPES; do
          for threads in $THREADS; do
            for mode in $mode_order; do
              run_case "$repeat" "$workload" "$threads" "$mode" "$shape"
            done
          done
        done
      else
        for threads in $THREADS; do
          for mode in $mode_order; do
            run_case "$repeat" "$workload" "$threads" "$mode"
          done
        done
      fi
    done
  done

  write_summary
  write_analysis
  write_profile_status_analysis
  write_final_plan_cache_status
  write_error_log_summary
  echo "results: $OUT_DIR"
}

main "$@"
