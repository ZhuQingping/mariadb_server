#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=${ROOT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/build_plan_cache_release"}
OUT_DIR=${OUT_DIR:-"/tmp/mariadb-plan-cache-linearity-diagnostic/$(date +%Y%m%d-%H%M%S)"}
LUA_DIR=${LUA_DIR:-}

# shellcheck source=Docs/plan_cache_community/benchmark_env.sh
. "$ROOT_DIR/Docs/plan_cache_community/benchmark_env.sh"

TABLES=${TABLES:-64}
TABLE_SIZE=${TABLE_SIZE:-50000}
THREADS=${THREADS:-"1 2 4 8"}
WORKLOADS=${WORKLOADS:-"oltp_point_select oltp_read_only"}
RUN_TIME=${RUN_TIME:-60}
PREWARM_TIME=${PREWARM_TIME:-30}
BUFFER_POOL_SIZE=${BUFFER_POOL_SIZE:-10G}
SERVER_EXTRA_OPTS=${SERVER_EXTRA_OPTS:-}
PLAN_CACHE_MODE=${PLAN_CACHE_MODE:-OFF}
SYSBENCH_IGNORE_ERRORS=${SYSBENCH_IGNORE_ERRORS:-}
PREFLIGHT_ONLY=${PREFLIGHT_ONLY:-0}

MYSQL="$BUILD_DIR/client/mariadb --no-defaults"
ADMIN="$BUILD_DIR/client/mariadb-admin --no-defaults"
BASE=""
DATADIR=""
SOCKET=""
PIDFILE=""
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

require_release_build() {
  test -x "$BUILD_DIR/sql/mariadbd" || die "missing $BUILD_DIR/sql/mariadbd"
  test -x "$BUILD_DIR/client/mariadb" || die "missing $BUILD_DIR/client/mariadb"
  test -x "$BUILD_DIR/client/mariadb-admin" || die "missing $BUILD_DIR/client/mariadb-admin"
  test -x "$BUILD_DIR/scripts/mariadb-install-db" || die "missing $BUILD_DIR/scripts/mariadb-install-db"
  grep -q '^CMAKE_BUILD_TYPE:STRING=Release$' "$BUILD_DIR/CMakeCache.txt" ||
    die "build is not CMAKE_BUILD_TYPE=Release"
  grep -q '^WITH_ASAN:BOOL=OFF$' "$BUILD_DIR/CMakeCache.txt" ||
    die "build has WITH_ASAN enabled"
}

preflight() {
  require_release_build
  resolve_lua_dir
  command -v sysbench >/dev/null 2>&1 || die "missing sysbench command"
  for workload in $WORKLOADS; do
    test -f "$LUA_DIR/$workload.lua" ||
      die "missing sysbench workload Lua: $LUA_DIR/$workload.lua"
  done

  echo "preflight_ok=1"
  echo "build_dir=$BUILD_DIR"
  echo "lua_dir=$LUA_DIR"
  echo "sysbench=$(sysbench --version)"
  echo "plan_cache_mode=$PLAN_CACHE_MODE"
}

status_value() {
  local key=$1
  $MYSQL --socket="$SOCKET" -uroot -N -e "SHOW GLOBAL STATUS LIKE '$key'" |
    awk '{print $2}'
}

status_snapshot() {
  local file=$1
  $MYSQL --socket="$SOCKET" -uroot -N -e "
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'Threads_connected',
  'Threads_running',
  'Opened_tables',
  'Opened_table_definitions',
  'Open_tables',
  'Open_table_definitions',
  'Table_open_cache_hits',
  'Table_open_cache_misses',
  'Table_open_cache_overflows',
  'Handler_read_key',
  'Handler_read_next',
  'Handler_read_rnd_next',
  'Created_tmp_tables',
  'Created_tmp_disk_tables',
  'Cached_plan_count',
  'Cached_plan_hits',
  'Cached_plan_invalidations'
);
SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'table_open_cache',
  'table_definition_cache',
  'table_open_cache_instances',
  'thread_cache_size',
  'max_connections',
  'innodb_buffer_pool_size'
);" > "$file"
}

cpu_sampler() {
  local pid=$1
  local output=$2
  while true; do
    ps -p "$pid" -o %cpu= 2>/dev/null || true
    sleep 1
  done > "$output"
}

parse_field() {
  local file=$1
  local pattern=$2
  awk -v pat="$pattern" '$0 ~ pat {gsub(/[()]/, "", $3); print $3}' "$file"
}

parse_latency_avg() {
  awk '/^[[:space:]]*avg:/ {print $2}' "$1"
}

workload_extra_args() {
  local workload=$1
  if [ "$workload" = "oltp_read_only" ]; then
    echo "--range_selects=0 --skip-trx=1"
  fi
}

cpu_stats_excluding_first_sample() {
  local file=$1
  awk 'NR > 1 && NF {sum+=$1; n++; if (min=="" || $1<min) min=$1; if ($1>max) max=$1}
       END {if (n) printf "%.2f\t%.2f\t%.2f\n", sum/n, min, max; else printf "0.00\t0.00\t0.00\n"}' "$file"
}

status_delta() {
  local before=$1
  local after=$2
  local key=$3
  awk -v key="$key" 'FNR==NR {if($1==key) b=$2; next} $1==key {print $2-b}' "$before" "$after"
}

run_case() {
  local workload=$1
  local threads=$2
  local lua="$LUA_DIR/$workload.lua"
  local out="$OUT_DIR/raw/${workload}_t${threads}.out"
  local server_cpu="$OUT_DIR/raw/${workload}_t${threads}.server.cpu"
  local client_cpu="$OUT_DIR/raw/${workload}_t${threads}.client.cpu"
  local before="$OUT_DIR/raw/${workload}_t${threads}.status.before"
  local after="$OUT_DIR/raw/${workload}_t${threads}.status.after"
  local server_pid
  server_pid=$(cat "$PIDFILE")

  status_snapshot "$before"
  cpu_sampler "$server_pid" "$server_cpu" &
  local server_cpu_pid=$!

  # shellcheck disable=SC2086
  sysbench "$lua" "${COMMON[@]}" $(workload_extra_args "$workload") \
    --threads="$threads" --time="$RUN_TIME" --events=0 \
    --percentile=95 --report-interval=1 run > "$out" 2>&1 &
  local client_pid=$!
  cpu_sampler "$client_pid" "$client_cpu" &
  local client_cpu_pid=$!

  wait "$client_pid"
  kill "$server_cpu_pid" "$client_cpu_pid" >/dev/null 2>&1 || true
  wait "$server_cpu_pid" "$client_cpu_pid" 2>/dev/null || true
  status_snapshot "$after"

  local tps qps lat_avg server_avg server_min server_max client_avg client_min client_max
  tps=$(parse_field "$out" "transactions:")
  qps=$(parse_field "$out" "queries:")
  lat_avg=$(parse_latency_avg "$out")
  IFS=$'\t' read -r server_avg server_min server_max < <(cpu_stats_excluding_first_sample "$server_cpu")
  IFS=$'\t' read -r client_avg client_min client_max < <(cpu_stats_excluding_first_sample "$client_cpu")

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$workload" "$threads" "$tps" "$qps" "$lat_avg" \
    "$server_avg" "$server_min" "$server_max" \
    "$client_avg" "$client_min" "$client_max" \
    "$(status_delta "$before" "$after" Table_open_cache_misses)" \
    "$(status_delta "$before" "$after" Table_open_cache_overflows)" \
    "$(status_delta "$before" "$after" Opened_tables)" \
    "$(status_delta "$before" "$after" Opened_table_definitions)" \
    "$(status_delta "$before" "$after" Created_tmp_disk_tables)" >> "$OUT_DIR/results.tsv"
}

main() {
  if [ "$PREFLIGHT_ONLY" = "1" ]; then
    preflight
    return
  fi

  preflight >/dev/null
  mkdir -p "$OUT_DIR/raw"
  BASE="/tmp/mariadb-plan-cache-linearity-diagnostic-$(date +%Y%m%d-%H%M%S)-$$"
  DATADIR="$BASE/data"
  SOCKET="$BASE/mariadb.sock"
  PIDFILE="$BASE/mariadbd.pid"
  local port=$((38000 + ($$ % 1000)))
  trap cleanup EXIT
  mkdir -p "$DATADIR"

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
    echo "plan_cache_mode=$PLAN_CACHE_MODE"
    echo "sysbench_ignore_errors=${SYSBENCH_IGNORE_ERRORS:-not-set}"
    echo "server_extra_opts=$SERVER_EXTRA_OPTS"
    uname -a
    write_benchmark_host_env
  } > "$OUT_DIR/environment.txt"

  "$BUILD_DIR/scripts/mariadb-install-db" \
    --no-defaults --force --srcdir="$ROOT_DIR" --builddir="$BUILD_DIR" \
    --datadir="$DATADIR" --auth-root-authentication-method=normal \
    --skip-test-db > "$OUT_DIR/install-db.log" 2>&1

  # shellcheck disable=SC2086
  "$BUILD_DIR/sql/mariadbd" \
    --no-defaults --datadir="$DATADIR" --socket="$SOCKET" --port="$port" \
    --bind-address=127.0.0.1 --pid-file="$PIDFILE" \
    --log-error="$OUT_DIR/mariadbd.err" --skip-log-bin \
    --innodb-buffer-pool-size="$BUFFER_POOL_SIZE" \
    --innodb-buffer-pool-load-at-startup=OFF \
    --innodb-buffer-pool-dump-at-shutdown=OFF \
    --innodb-flush-log-at-trx-commit=2 --innodb-doublewrite=0 \
    --performance-schema=OFF --table-open-cache=65536 \
    --table-definition-cache=65536 --table-open-cache-instances=16 \
    --thread-cache-size=512 --max-connections=2048 \
    $SERVER_EXTRA_OPTS > "$OUT_DIR/mariadbd.stdout" 2>&1 &

  for _ in $(seq 1 90); do
    if $ADMIN --socket="$SOCKET" -uroot ping >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  $ADMIN --socket="$SOCKET" -uroot ping >/dev/null 2>&1 ||
    die "server failed to start; see $OUT_DIR/mariadbd.err"

  $MYSQL --socket="$SOCKET" -uroot -e "CREATE DATABASE sbtest"
  $MYSQL --socket="$SOCKET" -uroot -e \
    "SET GLOBAL session_plan_cache=$PLAN_CACHE_MODE; SET GLOBAL session_plan_cache_allow_change_ratio=0"
  COMMON=(--mysql-socket="$SOCKET" --mysql-user=root --mysql-db=sbtest
    --db-driver=mysql --db-ps-mode=auto
    --mysql-storage-engine=innodb --tables="$TABLES" --table-size="$TABLE_SIZE"
    --rand-type=uniform)
  if [ -n "$SYSBENCH_IGNORE_ERRORS" ]; then
    COMMON+=(--mysql-ignore-errors="$SYSBENCH_IGNORE_ERRORS")
  fi

  sysbench "$LUA_DIR/oltp_read_only.lua" "${COMMON[@]}" cleanup >/dev/null 2>&1 || true
  sysbench "$LUA_DIR/oltp_read_only.lua" "${COMMON[@]}" prepare > "$OUT_DIR/prepare.log"
  sysbench "$LUA_DIR/oltp_read_only.lua" "${COMMON[@]}" \
    --range_selects=0 --skip-trx=1 --threads=16 --time="$PREWARM_TIME" \
    --events=0 --percentile=95 --report-interval=10 run > "$OUT_DIR/prewarm.log"

  printf "workload\tthreads\ttps\tqps\tlat_avg_ms\tserver_cpu_avg\tserver_cpu_min\tserver_cpu_max\tclient_cpu_avg\tclient_cpu_min\tclient_cpu_max\ttable_open_cache_misses_delta\ttable_open_cache_overflows_delta\topened_tables_delta\topened_table_definitions_delta\tcreated_tmp_disk_tables_delta\n" \
    > "$OUT_DIR/results.tsv"

  for workload in $WORKLOADS; do
    for threads in $THREADS; do
      run_case "$workload" "$threads"
    done
  done

  echo "results: $OUT_DIR"
}

main "$@"
