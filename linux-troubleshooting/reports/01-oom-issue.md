[Bug] MEMORY_LIMIT 이하 성장 후 MemoryGuard에 의한 강제 종료(SIGKILL)

## 1. Description (현상 설명)

`agent-leak-app` 실행 후 약 9~12초가 지나면 프로세스가 예고 없이 종료된다.
`MEMORY_LIMIT`을 256MB 이하로 설정한 모든 실행(테스트값: 90, 100, 200, 254, 255, 256)에서
100% 재현됐고, 257 이상에서는 재현되지 않았다 — 즉 조건은 절대적인 메모리 사용량이
아니라 **`MEMORY_LIMIT` 자체가 256을 넘는지 여부**다.

## 2. Evidence & Logs (증거 자료)

**monitor.sh 결과** (`evidence/oom-monitor-sh.log`) — 성장 중엔 `[OK]`로 MEM%가
0.3%→0.4%로 오르다가, 크래시 직후 재실행하면 `[FAIL] ... PID=none, port 15034 LISTEN=0`.

**앱 실행 로그** (`evidence/oom-growth-and-crash.log`) — 25MB 단위로 성장하다
`heap >= MEMORY_LIMIT`이 되는 첫 시점에서 즉시 종료:
```
[INFO] [MemoryWorker] Current Heap: 100MB
[CRITICAL] [MemoryGuard] Memory limit exceeded (100MB >= 100MB) / (Recommend Over 256MB)
[CRITICAL] [MemoryGuard] Self-terminating process 99451 to prevent system instability.
```
`MEMORY_LIMIT=90`(25의 배수가 아닌 값)으로도 같은 실험을 했더니 정확히 `100MB >= 90MB`에서
걸렸다 — 25MB 성장 틱과 `>=` 비교가 항상 같은 방식으로 작동한다는 뜻이다.

**[보강 · 표준 동적 관측(디버깅), 필수요건 밖]** (`evidence/oom-selfkill-strace.log`) — `strace -f`로
종료 순간을 직접 잡았다:
```
kill(102313, SIGKILL) = ?
tgkill(102312, 102312, SIGKILL) = ?
```
호출자 PID == 대상 PID — 커널의 OOM killer가 아니라 프로세스가 **자기 자신에게** 신호를
보내는 자체 종료다. `dmesg`로 커널 OOM 로그도 확인하려 했으나 권한 부족(`Operation not
permitted`)으로 실패했다 — 다만 앱 로그가 이미 `[MemoryGuard] Self-terminating process …`로
자가종료를 명시하므로 결론은 블랙박스 로그만으로 서고, 이 strace는 syscall 레벨 확인용 보강이다.
이 시스템의 실제 RAM 대비 테스트에 쓴 한도(90~256MB)는 진짜 커널 OOM이 걸릴 상황이 아니었다.

## 3. Root Cause Analysis (원인 분석)

**MemoryWorker**가 25MB 청크를 3초 간격으로 계속 할당한다. **MemoryGuard**가 매 틱마다
`현재 heap >= MEMORY_LIMIT`를 검사하고, 참이 되는 순간 `kill(self, SIGKILL)`을 호출해
프로세스를 즉시 종료시킨다. SIGKILL은 캐치 불가능·정리 코드 실행 불가능이라, CRITICAL
로그 두 줄 이후 어떤 후속 출력도 없이 프로세스가 사라진다(리눅스 커널이 SIGKILL을
가로챌 수 없게 만드는 것과 동일한 성질 — 진짜 OOM killer의 동작을 정확히 흉내낸 설계).

**관련 OS 동작 원리**: 이는 애플리케이션 계층의 자원 거버넌스 정책이다. 리눅스 커널의
진짜 OOM killer는 전역 메모리 압박 시 `badness` 점수로 희생 프로세스를 골라 SIGKILL을
보내는데, 이 앱은 그 흉내를 자기 프로세스 내부 정책으로 재현한다 — 시스템 전체가 아니라
자기 자신의 소비량만 감시한다는 점이 실제 커널 OOM killer와의 차이다.

**추가 실측(참고)**: `MEMORY_LIMIT > 256`으로 두면 같은 성장 로직이 임계치(성장분≥
설정값이 되는 첫 25MB 틱, 예: 512 설정 시 525MB)에서 `munmap()`으로 청크를 하나씩
실제 해제하고 처음부터 다시 시작한다(`evidence/oom-healthy-cleanup-and-rss.log` —
실측 RSS가 530MB→18MB로 폭락, 20개의 25MB `munmap` syscall로 확인). 즉 이 메모리는
한 번도 "참조를 잃어 회수 불가능한" 상태였던 적이 없다 — 같은 회수 가능한 청크를
정책적으로 죽일지 살릴지가 `MEMORY_LIMIT` 값 하나로 갈릴 뿐이다.

## 4. Workaround & Verification (조치 및 검증)

**조치**: `MEMORY_LIMIT`을 100 → 512로 상향.

**Before**: `MEMORY_LIMIT=100`, 부팅 후 9초(01:47:53~01:48:02)만에 CRITICAL로 강제 종료.

**After**: `MEMORY_LIMIT=512`, 60초 시점에 525MB까지 성장 → cleanup(실제 RSS 해제 확인) →
25MB로 리셋 후 재성장 → 이후 관찰한 모든 구간에서 생존, monitor.sh 헬스체크 계속 `[OK]`.

**근본적 해결 제안**: `MEMORY_LIMIT`을 실사용량보다 여유 있게(256 초과로) 설정하는 것은
증상 회피일 뿐 근본 해결이 아니다 — MemoryWorker가 애초에 상한 없이 계속 할당하는
설계 자체가 문제이므로, 청크 수에 자체 상한을 두거나 주기적 cleanup을 `MEMORY_LIMIT`
크기와 무관하게 항상 수행하도록 바꾸는 편이 근본적이다.
