# B1-1 — 시스템 관제 자동화 스크립트 (과제 원문)

> 분야 AI/SW 기초 · 구분 Linux와 OS · 학습시간 40h.
> 관련: [agent-app 역분석](agent-app-analysis.md) · [수행 내역서](submission-notes.md)

## 1. 미션 소개

다중 사용자 환경의 권한 관리·네트워크 보안 설정에서 시작해, 서비스 배포·운영 시 필수인
시스템 리소스 관제와 로그 관리를 자동화하는 쉘 스크립트를 개발한다.
최종: 애플리케이션 배포 환경 구축 + 시스템 상태 관제·데이터 기록 역량.

## 2. 최종 결과물 (2종)

1. **요구사항 수행 내역서** (문서) — 설정/명령어 기록 + 필수 증거 체크리스트.
2. **자동화 스크립트 소스** — `monitor.sh`.

### 필수 증거 체크리스트

- SSH 포트 20022 변경 + Root 원격 차단
- 방화벽(UFW/firewalld) 활성 + 20022/tcp, 15034/tcp만 허용
- 계정/그룹(agent-admin/dev/test, agent-common/core) 생성
- 디렉토리 구조·권한(ACL 포함)
- 앱 Boot Sequence 5단계 [OK] + "Agent READY"
- `monitor.sh` 실행 결과(프로세스/포트/리소스/경고)
- `/var/log/agent-app/monitor.log` 누적 기록
- crontab 매분 실행 등록 + 1분 후 로그 증가

## 3. 과제 목표 (설명할 수 있어야)

- SSH 포트 변경·Root 차단이 왜 기본 보안인지
- 방화벽 "필요 포트만 허용" 구성·검증
- 역할 기반 계정/그룹·ACL로 공유/보안 디렉토리 분리하는 이유
- 환경변수(AGENT_HOME 등)로 실행 환경 고정하는 이유·검증
- 쉘 스크립트로 프로세스/포트/리소스 수집·로깅해 운영 문제 추적
- crontab 주기 실행 + 로그 보존 정책(압축/삭제)의 필요성

## 4. 기능 요구 사항

### 4-1. 보안·네트워크

- **SSH**: 포트 20022, Root 원격 로그인 차단.
  - 확인: sshd 설정 파일 · `ss -tulnp`
- **방화벽(택1)**: UFW 또는 firewalld 활성. 인바운드 **TCP 20022(SSH), 15034(APP)만** 허용.
  - 확인: `ufw status` / `firewall-cmd --list-all`

### 4-2. 계정·그룹·권한

- 계정: `agent-admin`(운영/관리, cron 실행자) · `agent-dev`(개발/운영, monitor.sh 작성자) · `agent-test`(QA)
- 그룹: `agent-common`(admin·dev·test) · `agent-core`(admin·dev)
- 디렉토리(AGENT_HOME 기준):
  - `$AGENT_HOME` · `$AGENT_HOME/upload_files` · `$AGENT_HOME/api_keys` · `/var/log/agent-app`
- 접근 권한(핵심):
  - `upload_files`: group=agent-common, R/W
  - `api_keys` 및 `/var/log/agent-app`: group=agent-core ONLY, R/W
  - 확인: `id agent-*` · `ls -l` · `getfacl`

### 4-3. 앱 실행 환경 (제공 Python 앱)

- 환경변수:
  - `AGENT_HOME` (예: `/home/agent-admin/agent-app`)
  - `AGENT_PORT` = 15034
  - `AGENT_UPLOAD_DIR` = `$AGENT_HOME/upload_files`
  - `AGENT_KEY_PATH` = `$AGENT_HOME/api_keys/t_secret.key`
  - `AGENT_LOG_DIR` = `/var/log/agent-app` (지정 권장)
- 키파일: `$AGENT_HOME/api_keys/t_secret.key`, 내용 `agent_api_key_test` (1줄)
- 실행 성공 기준:
  - 일반 계정 실행(루트 금지)
  - Boot 5단계 모두 [OK] + 마지막 "Agent READY"
  - `0.0.0.0:15034` LISTEN
  - 종료 = Ctrl+C

### 4-4. monitor.sh

- 경로 `$AGENT_HOME/bin/monitor.sh` / 소유 agent-dev / 그룹 agent-core / 권한 750
- cron 실행 계정 = agent-admin (agent-core 포함이라 실행 가능)
- **Health Check(실패 시 exit 1)**: 프로세스 `agent_app.py` 실행 상태 · 포트 15034 LISTEN
- **상태 점검(경고만)**: 방화벽 비활성 시 `[WARNING]`, 스크립트는 계속
- **자원 수집**: CPU% · MEM% · DISK(root Used %)
- **임계 경고(경고만)**: CPU>20% · MEM>10% · DISK_USED>80%
- **로그**: `/var/log/agent-app/monitor.log`
  - 포맷: `[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%`
  - 용량 관리: 최대 10MB / 10개 (logrotate 또는 스크립트 로직)
- **cron**: agent-admin crontab, 매분 실행. 등록 후 1~2분 내 로그 누적 확인

## 5. 보너스 (선택)

- **보너스 1 — `report.sh`**: monitor.log 분석해 CPU/MEM/DISK 평균/최대/최소 + 샘플 수 출력. (선택) 시작/종료 시간 구간 분석.
- **보너스 2 — 시간 기반 로그 보존**:
  - 7일 경과 로그 압축 (`/var/log/agent-app/*.log`)
  - 아카이브 이동 (`/var/log/monitor/agent-app/archive/`)
  - 30일 경과 아카이브(`*.gz`) 삭제
  - (권장) 예외 처리: 디렉토리 미존재·권한 부족·대상 0개 시 안전 종료/경고

## 6. 개발 환경

- Ubuntu 22.04 LTS 또는 동등 리눅스 (이전 미션 컨테이너/VM 권장)

## 7. 제약

- 자동화 스크립트는 **Bash로만** (Python 등 대체 금지)
- 필요 시에만 sudo (가능한 일반 계정)
- 제공 Python 앱 = "실행 대상", 과제 핵심은 관제/자동화 스크립트

## 8. 결과 예시 (참고, 정답 아님)

앱 Boot: `[1/5]~[5/5] [OK]` → "All Boot Checks Passed! / Agent READY".
monitor.sh 콘솔: HEALTH CHECK · RESOURCE MONITORING · WARNING · STATISTICS REPORT.
monitor.log: `[2026-02-25 13:58:01] PID:48291 CPU:10.2% MEM:3.2% DISK_USED:23%`

## 데이터 파일

- `agent-app.zip` → `agent-app-linux-x86` (x86) · `agent-app-linux-arm64` (Apple arm)
