# B1-1 — 요구사항 수행 내역서 (템플릿)

> 결과물 2종 중 문서 쪽. 아래 "결과(붙여넣기)"는 **실제 VM/컨테이너에서 명령을 실행한 뒤** 그 출력을 그대로 붙여넣는 자리 — 지금은 전부 빈칸이다 (평가용 증거라 실행 없이 채우면 안 됨).
> 환경: Ubuntu 22.04 LTS 컨테이너/VM. `AGENT_HOME=/home/agent-admin/agent-app` 가정 — 실제 경로 다르면 전부 치환.
> 순서 = 의존성 순서(계정·디렉토리가 먼저 있어야 그 밑에 env 파일을 쓸 수 있다) — spec.md §4 순서와 동일.
> 관련: [과제 원문](spec.md) · [agent-app 역분석](agent-app-analysis.md) · [monitor.sh](monitor.sh)

## 1. SSH 포트 변경 + Root 원격 차단

```bash
sudo sed -i 's/^#\?Port .*/Port 20022/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

확인:
```bash
sudo grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config
ss -tulnp | grep 20022
```
결과(붙여넣기):
```
(여기)
```

## 2. 방화벽 — UFW, 20022/15034만 허용

```bash
sudo apt install -y ufw          # 미설치 시
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
결과(붙여넣기):
```
(여기)
```

## 3. 계정 · 그룹 · 디렉토리 · 권한(ACL)

```bash
sudo groupadd agent-common
sudo groupadd agent-core

sudo useradd -m -s /bin/bash agent-admin
sudo useradd -m -s /bin/bash agent-dev
sudo useradd -m -s /bin/bash agent-test

# agent-common = admin·dev·test / agent-core = admin·dev
sudo usermod -aG agent-common,agent-core agent-admin
sudo usermod -aG agent-common,agent-core agent-dev
sudo usermod -aG agent-common agent-test
```

디렉토리 + 권한:
```bash
export AGENT_HOME=/home/agent-admin/agent-app
# agent-admin 홈 밑이므로 agent-admin 소유로 만든다(root가 만들면 owner가 root로
# 남아 나중에 -R chown이 필요해지고, 그 chown -R이 아래 그룹 분리를 되돌리는 사고를
# 유발하기 쉽다 — 처음부터 agent-admin 소유로 시작해 그 문제 자체를 없앤다).
sudo -u agent-admin mkdir -p "$AGENT_HOME"/{bin,upload_files,api_keys}
sudo mkdir -p /var/log/agent-app   # /var 밑은 시스템 로그 디렉토리라 root 소유가 정상

# upload_files: agent-common 그룹 R/W
sudo chgrp agent-common "$AGENT_HOME/upload_files"
sudo chmod 770 "$AGENT_HOME/upload_files"
sudo setfacl -m g:agent-common:rwx "$AGENT_HOME/upload_files"
sudo setfacl -d -m g:agent-common:rwx "$AGENT_HOME/upload_files"

# api_keys, /var/log/agent-app: agent-core 그룹만 R/W
sudo chgrp agent-core "$AGENT_HOME/api_keys" /var/log/agent-app
sudo chmod 770 "$AGENT_HOME/api_keys" /var/log/agent-app
sudo setfacl -m g:agent-core:rwx "$AGENT_HOME/api_keys"
sudo setfacl -d -m g:agent-core:rwx "$AGENT_HOME/api_keys"
sudo setfacl -m g:agent-core:rwx /var/log/agent-app
sudo setfacl -d -m g:agent-core:rwx /var/log/agent-app

echo "agent_api_key_test" | sudo tee "$AGENT_HOME/api_keys/secret.key" >/dev/null
sudo chgrp agent-core "$AGENT_HOME/api_keys/secret.key"
sudo chmod 640 "$AGENT_HOME/api_keys/secret.key"
```

확인:
```bash
id agent-admin; id agent-dev; id agent-test
ls -l "$AGENT_HOME"
getfacl "$AGENT_HOME/upload_files" "$AGENT_HOME/api_keys" /var/log/agent-app
```
결과(붙여넣기):
```
(여기)
```

## 4. 환경변수 파일

`$AGENT_HOME/.env` — 지금 시점엔 AGENT_HOME이 이미 존재(§3)하니 바로 쓸 수 있다.
같은 쉘에서 이어 실행(§3의 `AGENT_HOME` 변수를 그대로 씀):

```bash
sudo -u agent-admin tee "$AGENT_HOME/.env" > /dev/null <<'EOF'
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR=/var/log/agent-app
EOF
sudo chown agent-admin:agent-core "$AGENT_HOME/.env"
sudo chmod 750 "$AGENT_HOME/.env"
```

앱 실행·monitor.sh·cron 전부 이 파일을 source해서 환경을 고정한다(과제 목표 §3 "환경변수로 실행 환경 고정" 항목).

> 관찰 메모 — agent-app-analysis.md §4 F·G(2026-07-18 직접 재현·관찰): 명세는 `AGENT_KEY_PATH`를
> 키 파일 경로(`.../t_secret.key`)로 쓰라지만, 실제 배포물은 **`api_keys` 디렉토리까지만** 기대하고
> 키 파일명도 `secret.key`(t 없음)를 기대한다. 위 `.env`는 명세가 아니라 실측값을 반영한다 —
> 명세대로 쓰면 Boot 2단계에서 즉시 `Key Path Mismatch`로 실패한다(직접 재현·확인).

확인:
```bash
sudo -u agent-admin bash -c 'source "$0" && env | grep ^AGENT_' "$AGENT_HOME/.env"
```
결과(붙여넣기):
```
(여기)
```

## 5. 앱 실행 (Boot Sequence 5단계)

```bash
# agent-app 바이너리 배치 — AGENT_HOME이 이미 agent-admin 소유라 이대로 두면 됨
# (§3을 agent-admin 소유로 만들어 뒀으므로 여기서 재귀 chown은 하지 않는다 —
#  했다가는 §3에서 나눈 upload_files/api_keys 그룹 분리를 되돌리게 된다)
sudo cp agent-app-linux-x86 "$AGENT_HOME/"
sudo chown agent-admin:agent-admin "$AGENT_HOME/agent-app-linux-x86"
sudo chmod +x "$AGENT_HOME/agent-app-linux-x86"

su - agent-admin
source /home/agent-admin/agent-app/.env
cd "$AGENT_HOME"
./agent-app-linux-x86        # 또는 -arm64
```
기대 출력: `[1/5]`~`[5/5] [OK]` → `All Boot Checks Passed! / Agent READY`.

확인(다른 터미널):
```bash
ss -tulnp | grep 15034
```
결과(붙여넣기):
```
(여기)
```

> 관찰 메모 — agent-app-analysis.md §2-2: 이 앱은 부팅 후 메모리를 256MB까지 올렸다 전부 반납하는 **경계 톱니파**를 낸다(누수 아님). 장시간 관찰 시 오르내림이 정상이다.

## 6. monitor.sh 설치 + 실행

```bash
sudo cp monitor.sh "$AGENT_HOME/bin/monitor.sh"
sudo chown agent-dev:agent-core "$AGENT_HOME/bin/monitor.sh"
sudo chmod 750 "$AGENT_HOME/bin/monitor.sh"

sudo -u agent-admin bash -c '
  source /home/agent-admin/agent-app/.env
  "$AGENT_HOME/bin/monitor.sh"
'
```
결과(붙여넣기 — HEALTH CHECK/RESOURCE MONITORING/WARNING 콘솔 전체):
```
(여기)
```

> 관찰 메모 — agent-app-analysis.md §4: 헬스체크는 프로세스명(`agent_app.py`) 대신 **포트 기반**으로 구현했다(불일치 A — 실제 배포 프로세스명이 명세와 다름, 이름 기준이면 환경마다 거짓 FAIL이 난다). CPU%는 1초 간격 두 시점 샘플이라 앱의 위상성 부하(§2-2)를 반영한다 — 버스트 구간에서 순간값이 높게 잡힐 수 있음.

## 7. `/var/log/agent-app/monitor.log` 누적 확인

```bash
sudo tail -5 /var/log/agent-app/monitor.log
```
결과(붙여넣기):
```
(여기)
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
sleep 90
sudo tail -5 /var/log/agent-app/monitor.log   # 새 줄이 늘었는지
```
결과(붙여넣기):
```
(여기)
```

## 9. 종합 판정 (직접 작성)

- [ ] 위 8개 항목 결과 전부 채움
- [ ] 실패/경고가 하나라도 나왔다면 원인 한 줄 메모 (예: "방화벽 WARNING — 이 컨테이너는 systemd 없어 ufw enable 실패, 대안 iptables 확인 중")
- [ ] 명세↔배포물 불일치 A~D(agent-app-analysis.md §4) 중 실제로 부딪힌 것 있으면 여기 기록 — 이게 "운영 문제 추적" 역량 증거다

(여기에 직접 서술)
