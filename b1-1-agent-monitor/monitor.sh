#!/bin/bash
#
# monitor.sh — B1-1 시스템 관제 자동화 스크립트
# 설치 경로: $AGENT_HOME/bin/monitor.sh  (owner agent-dev:agent-core, mode 750)
# 실행: agent-admin crontab, 매분 (* * * * *)
#
# 설계 근거 (agent-app-analysis.md 참고):
#   - 프로세스 탐지는 이름(agent_app.py)이 아니라 포트로 한다 — 배포 바이너리의
#     실제 프로세스명이 명세와 다르다(불일치 A: pgrep agent_app.py는 항상 빈 결과).
#   - CPU%는 순간 두 시점 샘플로 구한다 — 앱이 1초 주기로 최대 5초 CPU 버스트를
#     내는 위상성 부하라(analysis §2-2), ps의 누적평균은 그 위상을 감춘다.
#   - MEM%는 ps RSS 대신 /proc/<pid>/smaps_rollup 의 Pss를 쓴다 — RSS는 공유
#     페이지(런타임·라이브러리)를 중복 계상한다.

set -uo pipefail

# ---------------------------------------------------------------------------
# 환경
# ---------------------------------------------------------------------------
AGENT_PORT="${AGENT_PORT:-15034}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="$LOG_DIR/monitor.log"

readonly CPU_THRESHOLD=20
readonly MEM_THRESHOLD=10
readonly DISK_THRESHOLD=80
readonly CPU_SAMPLE_SEC=1                      # utime/stime 두 시점 샘플 간격(초)
readonly LOG_MAX_BYTES=$((10 * 1024 * 1024))   # 10MB
readonly LOG_MAX_FILES=10

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# 반환 0(true) = value > threshold. bash는 부동소수 비교가 안 되므로 awk로.
awk_gt() {
    awk -v v="$1" -v t="$2" 'BEGIN{ exit (v > t) ? 0 : 1 }'
}

# ---------------------------------------------------------------------------
# 로그 — 자체 회전(최대 10MB, 10개, logrotate 미의존)
# ---------------------------------------------------------------------------
rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$size" -lt "$LOG_MAX_BYTES" ] && return 0

    local i
    for ((i = LOG_MAX_FILES - 1; i >= 1; i--)); do
        [ -f "${LOG_FILE}.$i" ] && mv -f "${LOG_FILE}.$i" "${LOG_FILE}.$((i + 1))"
    done
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
    rm -f "${LOG_FILE}.$((LOG_MAX_FILES + 1))"
}

log_line() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    rotate_log_if_needed
    echo "$1" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# 프로세스 탐지 — 포트 우선, pgrep 보강 (불일치 A 대응)
# 전역 PID, PORT_LISTEN 설정
# ---------------------------------------------------------------------------
detect_pid_and_port() {
    local ss_line
    ss_line=$(ss -tln 2>/dev/null | awk -v port="$AGENT_PORT" '$4 ~ ":"port"$"')
    if [ -n "$ss_line" ]; then PORT_LISTEN=1; else PORT_LISTEN=0; fi

    PID=$(ss -tlnp 2>/dev/null | awk -v port="$AGENT_PORT" '$4 ~ ":"port"$"' \
          | grep -oP 'pid=\K[0-9]+' | head -1)
    if [ -z "$PID" ]; then
        # 보강 탐지. 패턴은 실제 배포 바이너리명(agent-app-linux-x86/-arm64)까지
        # 좁힌다 — 느슨한 "agent-app"는 우연히 그 문자열을 포함한 무관한 명령의
        # cmdline과도 매칭될 수 있다(pgrep -f는 전체 명령행을 본다).
        PID=$(pgrep -f "agent-app-linux" | head -1)
    fi
}

# ---------------------------------------------------------------------------
# CPU% — /proc/<pid>/stat 의 utime+stime 델타 / 시스템 전체 jiffies 델타
# ---------------------------------------------------------------------------
proc_jiffies() {
    local pid=$1 line rest
    line=$(cat "/proc/$pid/stat" 2>/dev/null) || { echo 0; return 1; }
    rest="${line##*) }"          # "pid (comm) " 접두 제거 — comm 안의 ')'까지 방어(마지막 ') '만 자름)
    set -- $rest
    echo $(( ${12:-0} + ${13:-0} ))   # 트림 후 위치 12=utime, 13=stime
}

total_jiffies() {
    local line
    line=$(head -1 /proc/stat)
    read -r _ u n s idl iow irq sirq steal _ <<< "$line"
    echo $(( u + n + s + idl + iow + irq + sirq + steal ))
}

measure_cpu_pct() {
    local pid=$1 p1 p2 t1 t2 dp dt
    p1=$(proc_jiffies "$pid") || { echo "0.0"; return; }
    t1=$(total_jiffies)
    sleep "$CPU_SAMPLE_SEC"
    p2=$(proc_jiffies "$pid") || { echo "0.0"; return; }
    t2=$(total_jiffies)
    dp=$((p2 - p1)); dt=$((t2 - t1))
    if [ "$dt" -le 0 ]; then
        echo "0.0"
    else
        awk -v p="$dp" -v t="$dt" 'BEGIN{printf "%.1f", (p/t)*100}'
    fi
}

# ---------------------------------------------------------------------------
# MEM% — smaps_rollup Pss 우선, 권한 부족 시 VmRSS 폴백
# ---------------------------------------------------------------------------
measure_mem_pct() {
    local pid=$1 mem_total_kb pss_kb
    mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    if [ -r "/proc/$pid/smaps_rollup" ]; then
        pss_kb=$(awk '/^Pss:/{s+=$2} END{print s+0}' "/proc/$pid/smaps_rollup")
    else
        pss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
        pss_kb=${pss_kb:-0}
    fi
    awk -v p="$pss_kb" -v t="$mem_total_kb" 'BEGIN{ if (t>0) printf "%.1f", (p/t)*100; else print "0.0" }'
}

measure_disk_pct() {
    df -P / | awk 'NR==2{gsub("%","",$5); print $5}'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    echo "===== HEALTH CHECK ====="
    detect_pid_and_port

    if [ -z "${PID:-}" ] || [ "$PORT_LISTEN" -ne 1 ]; then
        echo "[FAIL] agent-app health check failed (PID=${PID:-none}, port ${AGENT_PORT} LISTEN=${PORT_LISTEN})"
        log_line "[$(ts)] HEALTH_CHECK_FAIL PID:${PID:-none} PORT_LISTEN:${PORT_LISTEN}"
        exit 1
    fi
    echo "[OK] agent-app running (PID=$PID), port $AGENT_PORT LISTEN"

    echo "===== RESOURCE MONITORING ====="
    local cpu_pct mem_pct disk_pct
    cpu_pct=$(measure_cpu_pct "$PID")
    mem_pct=$(measure_mem_pct "$PID")
    disk_pct=$(measure_disk_pct)
    echo "PID:$PID  CPU:${cpu_pct}%  MEM:${mem_pct}%  DISK_USED:${disk_pct}%"

    echo "===== WARNING ====="
    local warned=0
    if command -v ufw >/dev/null 2>&1; then
        ufw status 2>/dev/null | grep -qi "Status: active" \
            || { echo "[WARNING] firewall(ufw) inactive"; warned=1; }
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --state 2>/dev/null | grep -q "running" \
            || { echo "[WARNING] firewall(firewalld) inactive"; warned=1; }
    else
        echo "[WARNING] no known firewall tool (ufw/firewalld) found"; warned=1
    fi
    awk_gt "$cpu_pct" "$CPU_THRESHOLD" && { echo "[WARNING] CPU ${cpu_pct}% > ${CPU_THRESHOLD}%"; warned=1; }
    awk_gt "$mem_pct" "$MEM_THRESHOLD" && { echo "[WARNING] MEM ${mem_pct}% > ${MEM_THRESHOLD}%"; warned=1; }
    awk_gt "$disk_pct" "$DISK_THRESHOLD" && { echo "[WARNING] DISK_USED ${disk_pct}% > ${DISK_THRESHOLD}%"; warned=1; }
    [ "$warned" -eq 0 ] && echo "(no warnings)"

    log_line "[$(ts)] PID:${PID} CPU:${cpu_pct}% MEM:${mem_pct}% DISK_USED:${disk_pct}%"
}

main "$@"
