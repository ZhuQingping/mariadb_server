#!/usr/bin/env bash

write_benchmark_host_env() {
  echo "ulimit_nofile=$(ulimit -n 2>/dev/null || true)"
  echo "ulimit_stack=$(ulimit -s 2>/dev/null || true)"
  command -v free >/dev/null 2>&1 && free -h || true
  command -v df >/dev/null 2>&1 && df -h "${OUT_DIR:-.}" /tmp 2>/dev/null || true
  command -v lscpu >/dev/null 2>&1 && lscpu || true
  command -v numactl >/dev/null 2>&1 && numactl --hardware 2>/dev/null || true
  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    echo "cpu0_scaling_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  fi
  if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo "intel_pstate_no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
  fi
  sysctl -n hw.memsize 2>/dev/null | awk '{print "hw_memsize="$1}' || true
  sysctl -n hw.ncpu 2>/dev/null | awk '{print "hw_ncpu="$1}' || true
  sysctl -n hw.perflevel0.physicalcpu 2>/dev/null | awk '{print "hw_perf_physical="$1}' || true
  sysctl hw.ncpu hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu \
    hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu 2>/dev/null || true
}

expand_cpu_set() {
  local cpuset=$1
  local part start end cpu
  local IFS=','
  for part in $cpuset; do
    [ -n "$part" ] || return 1
    case "$part" in
      *-*)
        start=${part%-*}
        end=${part#*-}
        [ -n "$start" ] && [ -n "$end" ] || return 1
        case "$start$end" in *[!0-9]*) return 1 ;; esac
        if [ "$start" -gt "$end" ]; then
          return 1
        fi
        cpu=$start
        while [ "$cpu" -le "$end" ]; do
          echo "$cpu"
          cpu=$((cpu + 1))
        done
        ;;
      *)
        case "$part" in
          *[!0-9]*) return 1 ;;
        esac
        echo "$part"
        ;;
    esac
  done
}

cpu_sets_overlap() {
  local left=$1
  local right=$2
  local left_cpu right_cpu
  for left_cpu in $(expand_cpu_set "$left"); do
    for right_cpu in $(expand_cpu_set "$right"); do
      if [ "$left_cpu" = "$right_cpu" ]; then
        return 0
      fi
    done
  done
  return 1
}

validate_formal_cpu_sets() {
  local required=$1
  local server_cpuset=$2
  local sysbench_cpuset=$3

  if [ "$required" != "1" ]; then
    echo "formal_cpuset_ok=not-required"
    return 0
  fi
  if [ -z "$server_cpuset" ] || [ -z "$sysbench_cpuset" ]; then
    echo "formal_cpuset_ok=0"
    echo "formal_cpuset_error=SERVER_CPUSET and SYSBENCH_CPUSET are required"
    return 1
  fi
  expand_cpu_set "$server_cpuset" >/dev/null ||
    {
      echo "formal_cpuset_ok=0"
      echo "formal_cpuset_error=invalid SERVER_CPUSET"
      return 1
    }
  expand_cpu_set "$sysbench_cpuset" >/dev/null ||
    {
      echo "formal_cpuset_ok=0"
      echo "formal_cpuset_error=invalid SYSBENCH_CPUSET"
      return 1
    }
  if cpu_sets_overlap "$server_cpuset" "$sysbench_cpuset"; then
    echo "formal_cpuset_ok=0"
    echo "formal_cpuset_error=SERVER_CPUSET overlaps SYSBENCH_CPUSET"
    return 1
  fi
  echo "formal_cpuset_ok=1"
}
