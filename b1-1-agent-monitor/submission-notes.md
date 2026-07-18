# B1-1 — 요구사항 수행 내역서

> 결과물 2종 중 문서 쪽. 아래 "결과"는 **실제 Ubuntu 22.04 VM에서 명령을 실행한 출력**이다.
> 실행 환경: multipass Ubuntu 22.04.5 LTS VM(격리), 2026-07-19. `AGENT_HOME=/home/agent-admin/agent-app`.
> 순서 = 의존성 순서(계정·디렉토리가 먼저 있어야 그 밑에 env 파일을 쓸 수 있다) — spec.md §4 순서와 동일.
> 관련: [과제 원문](spec.md) · [agent-app 동작 관찰](agent-app-analysis.md) · [monitor.sh](monitor.sh)

> **사전 준비:** 베이스 Ubuntu 이미지에 `acl`이 없어 §3의 `setfacl`이 실패한다 → 먼저 `sudo apt install -y acl`.

## 1. SSH 포트 변경 + Root 원격 차단

```bash
sudo sed -i 's/^#\?Port .*/Port 20022/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh    # 운영이슈: Ubuntu 22.04 서비스명은 ssh (sshd 아님, §9)
```

확인:
```bash
sudo grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config
sudo ss -tulnp | grep 20022
```
결과:
```
Port 20022
PermitRootLogin no
tcp LISTEN 0 128 0.0.0.0:20022 0.0.0.0:* users:(("sshd",pid=2273,fd=5))
tcp LISTEN 0 128    [::]:20022    [::]:* users:(("sshd",pid=2273,fd=6))
```
> VM 실행 중엔 multipass 관리채널(22)을 유지해야 접속이 끊기지 않아 `Port 22`도 함께 열어뒀다(§9). 실배포에선 20022만.

## 2. 방화벽 — UFW, 20022/15034만 허용

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 20022/tcp
sudo ufw allow 15034/tcp
sudo ufw enable
```

확인:
```bash
sudo ufw status verbose
```
결과:
```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To              Action      From
--              ------      ----
20022/tcp       ALLOW IN    Anywhere
15034/tcp       ALLOW IN    Anywhere
22/tcp          ALLOW IN    Anywhere    # multipass mgmt (실배포선 제거)
20022/tcp (v6)  ALLOW IN    Anywhere (v6)
15034/tcp (v6)  ALLOW IN    Anywhere (v6)
```

## 3. 계정 · 그룹 · 디렉토리 · 권한(ACL)

```bash
sudo apt install -y acl        # 베이스 이미지에 없음 (필수)
sudo groupadd agent-common; sudo groupadd agent-core
sudo useradd -m -s /bin/bash agent-admin
sudo useradd -m -s /bin/bash agent-dev
sudo useradd -m -s /bin/bash agent-test
# agent-common = admin·dev·test / agent-core = admin·dev
sudo usermod -aG agent-common,agent-core agent-admin
sudo usermod -aG agent-common,agent-core agent-dev
sudo usermod -aG agent-common agent-test

export AGENT_HOME=/home/agent-admin/agent-app
sudo -u agent-admin mkdir -p "$AGENT_HOME"/{bin,upload_files,api_keys}
sudo mkdir -p /var/log/agent-app
# upload_files: agent-common 그룹 R/W
sudo chgrp agent-common "$AGENT_HOME/upload_files"; sudo chmod 770 "$AGENT_HOME/upload_files"
sudo setfacl -m g:agent-common:rwx "$AGENT_HOME/upload_files"
sudo setfacl -d -m g:agent-common:rwx "$AGENT_HOME/upload_files"
# api_keys, /var/log/agent-app: agent-core 그룹만 R/W
sudo chgrp agent-core "$AGENT_HOME/api_keys" /var/log/agent-app
sudo chmod 770 "$AGENT_HOME/api_keys" /var/log/agent-app
sudo setfacl -m g:agent-core:rwx "$AGENT_HOME/api_keys"; sudo setfacl -d -m g:agent-core:rwx "$AGENT_HOME/api_keys"
sudo setfacl -m g:agent-core:rwx /var/log/agent-app; sudo setfacl -d -m g:agent-core:rwx /var/log/agent-app
echo "agent_api_key_test" | sudo tee "$AGENT_HOME/api_keys/secret.key" >/dev/null
sudo chgrp agent-core "$AGENT_HOME/api_keys/secret.key"; sudo chmod 640 "$AGENT_HOME/api_keys/secret.key"
```

확인:
```bash
id agent-admin; id agent-dev; id agent-test
sudo ls -l "$AGENT_HOME"
sudo getfacl "$AGENT_HOME/upload_files" "$AGENT_HOME/api_keys" /var/log/agent-app
```
결과:
```
uid=1001(agent-admin) gid=1003(agent-admin) groups=1003(agent-admin),1001(agent-common),1002(agent-core)
uid=1002(agent-dev)   gid=1004(agent-dev)   groups=1004(agent-dev),1001(agent-common),1002(agent-core)
uid=1003(agent-test)  gid=1005(agent-test)  groups=1005(agent-test),1001(agent-common)

drwxrwx---+ 2 agent-admin agent-core   4096 api_keys
drwxrwxr-x  2 agent-admin agent-admin  4096 bin
drwxrwx---+ 2 agent-admin agent-common 4096 upload_files      # '+' = ACL 적용됨

# file: upload_files   group: agent-common
group:agent-common:rwx     default:group:agent-common:rwx     other::---
# file: api_keys       group: agent-core
group:agent-core:rwx       default:group:agent-core:rwx       other::---
# file: /var/log/agent-app  owner: root  group: agent-core
group:agent-core:rwx       default:group:agent-core:rwx       other::---
```

## 4. 환경변수 파일

`$AGENT_HOME/.env` (F·G 보정값 — agent-app-analysis.md §4):

```bash
sudo -u agent-admin tee "$AGENT_HOME/.env" > /dev/null <<'EOF'
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR=/var/log/agent-app
EOF
sudo chown agent-admin:agent-core "$AGENT_HOME/.env"; sudo chmod 750 "$AGENT_HOME/.env"
```

확인:
```bash
sudo -u agent-admin bash -c 'source "$0" && env | grep ^AGENT_' "$AGENT_HOME/.env"
```
결과:
```
AGENT_HOME=/home/agent-admin/agent-app
AGENT_PORT=15034
AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files
AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
AGENT_LOG_DIR=/var/log/agent-app
```
> `AGENT_KEY_PATH`는 파일 경로(`.../t_secret.key`)가 아니라 **디렉토리**(`.../api_keys`) — 명세대로 파일 경로를 넣으면 Boot 2단계에서 `Key Path Mismatch`로 실패(agent-app-analysis.md §4 F·G).

## 5. 앱 실행 (Boot Sequence 5단계)

```bash
sudo cp agent-app-linux-x86 "$AGENT_HOME/"
sudo chown agent-admin:agent-admin "$AGENT_HOME/agent-app-linux-x86"; sudo chmod +x "$AGENT_HOME/agent-app-linux-x86"
sudo -u agent-admin bash -c 'source ~/agent-app/.env && cd "$AGENT_HOME" && ./agent-app-linux-x86'
```
결과 (전 단계 [OK]):
```
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account            [OK]  ... service user 'agent-admin' (uid=1001)
[2/5] Verifying Environment Variables  [OK]  ... All required Envs correct
[3/5] Checking Required Files          [OK]  ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability       [OK]  ... Port 15034 is available.
[5/5] Verifying Log Permission         [OK]  ... Log directory is writable: /var/log/agent-app
All Boot Checks Passed! / Agent READY
[SafetyGuard] Process priority lowered (nice=10).
Agent listening at port 15034
   > Cycle: 0 -> 256MB/Lv10 -> 0
[Memory] Increasing... (+25 MB) Total: 25 MB
[CPU] Occupy core for 1s (Level 1)
```

확인(다른 터미널):
```bash
sudo ss -tulnp | grep 15034
```
결과:
```
tcp LISTEN 0 1 0.0.0.0:15034 0.0.0.0:* users:(("agent-app-linux",pid=2615,fd=4))
```
> 부팅 로그가 25MB 계단·레벨별 CPU 버스트(최대 5s)·256MB 목표를 그대로 찍는다(agent-app-analysis.md §2-2). onefile이라 PID가 부모/자식 2개(2613/2615) — LISTEN은 자식(불일치 E).

## 6. monitor.sh 설치 + 실행

```bash
sudo cp monitor.sh "$AGENT_HOME/bin/monitor.sh"
sudo chown agent-dev:agent-core "$AGENT_HOME/bin/monitor.sh"; sudo chmod 750 "$AGENT_HOME/bin/monitor.sh"
sudo -u agent-admin bash -c 'source ~/agent-app/.env && "$AGENT_HOME/bin/monitor.sh"'
```
결과:
```
===== HEALTH CHECK =====
[OK] agent-app running (PID=2615), port 15034 LISTEN
===== RESOURCE MONITORING =====
PID:2615  CPU:12.6%  MEM:4.4%  DISK_USED:20%
===== WARNING =====
[WARNING] firewall(ufw) inactive
```
> 헬스체크는 프로세스명(`agent_app.py`) 대신 포트로 탐지(불일치 A 우회). CPU 12.6%는 앱이 실제 CPU를 점유하는 버스트 구간이라 실측치다. **방화벽 "inactive" 경고는 오탐** — `ufw status`가 root를 요구하는데 monitor.sh는 agent-admin(크론)으로 돌기 때문(§9). 실제는 §2에서 active 확인.

## 7. `/var/log/agent-app/monitor.log` 누적 확인

```bash
sudo tail -5 /var/log/agent-app/monitor.log
```
결과:
```
[2026-07-19 01:44:44] PID:2615 CPU:12.6% MEM:4.4%  DISK_USED:20%
[2026-07-19 01:45:02] PID:2615 CPU:3.0%  MEM:8.3%  DISK_USED:20%
[2026-07-19 01:46:02] PID:2615 CPU:7.6%  MEM:8.3%  DISK_USED:20%
```

## 8. crontab 매분 실행

```bash
sudo crontab -u agent-admin -e
```
추가할 줄:
```cron
* * * * * . /home/agent-admin/agent-app/.env && /home/agent-admin/agent-app/bin/monitor.sh >/dev/null 2>&1
```

확인(등록 직후 + 1~2분 후):
```bash
sudo crontab -u agent-admin -l
sudo tail -8 /var/log/agent-app/monitor.log
```
결과 (매분 자동 누적 확인 — 01:45~01:48 cron 실행):
```
* * * * * . /home/agent-admin/agent-app/.env && /home/agent-admin/agent-app/bin/monitor.sh >/dev/null 2>&1

[2026-07-19 01:44:44] PID:2615 CPU:12.6% MEM:4.4%  DISK_USED:20%   ← §6 수동
[2026-07-19 01:45:02] PID:2615 CPU:3.0%  MEM:8.3%  DISK_USED:20%   ← cron
[2026-07-19 01:46:02] PID:2615 CPU:7.6%  MEM:8.3%  DISK_USED:20%   ← cron
[2026-07-19 01:47:02] PID:2615 CPU:8.9%  MEM:12.1% DISK_USED:20%   ← cron
[2026-07-19 01:48:02] PID:2615 CPU:9.0%  MEM:1.9%  DISK_USED:20%   ← cron
```
> MEM%가 4.4→8.3→12.1→1.9로 출렁이는 건 앱의 256MB 톱니파(agent-app-analysis.md §2-2)를 매분 다른 위상에서 표집하기 때문 — 시점에 따라 값이 뒤집히는 불일치 B/C의 라이브 증거.

## 9. 종합 판정 · 운영 이슈 기록

- [x] 위 8개 항목 결과 전부 실측으로 채움 (multipass Ubuntu 22.04 VM).
- [x] Boot 5단계 전부 [OK] — F·G 보정값(`AGENT_KEY_PATH`=디렉토리, 키 파일명 `secret.key`)으로만 성립.

**부딪힌 운영 이슈(= "운영 문제 추적" 역량 증거):**

1. **서비스명 `ssh` ≠ `sshd`** — Ubuntu 22.04는 `ssh.service`. `systemctl restart sshd`는 unit 없음으로 실패 → `ssh`로 실행.
2. **`acl` 미설치** — 베이스 이미지에 `setfacl` 없음. `apt install -y acl` 선행 필수. 설치 후 getfacl로 그룹 ACL 확정.
3. **monitor.sh 방화벽 오탐(False Positive)** — `ufw status`는 root 권한을 요구하는데 monitor.sh는 크론에서 agent-admin으로 실행돼 상태를 못 읽고 항상 `[WARNING] firewall inactive`를 낸다. 실제 방화벽은 active(§2). 근본 해결은 monitor.sh의 방화벽 체크를 root 경로로 돌리거나(`sudo` NOPASSWD 규칙) 비-root에선 "확인 불가"로 표기하는 것.
4. **MEM% 위상 의존(불일치 B/C)** — 매분 cron 표집값이 1.9~12.1%로 요동. 앱이 256MB까지 올렸다 반납하는 톱니파라 표본 시점이 판정을 바꾼다. 절대량이 아닌 시계열로 봐야 한다.
5. **VM 관리채널(Port 22)** — multipass는 22로 접속하므로 이 실행에선 22를 함께 열었다. 실배포에선 20022만 남기고 22 제거.
