[Bug] CpuWorker "Current Load"가 실제 CPU와 무관한 가짜 카운터 — 고정 50% 킬라인에서 SIGTERM 자가종료 (CPU_MAX_OCCUPY와 별개)

## 1. Description (현상 설명)

`CPU_MAX_OCCUPY=100`으로 실행하면 15~40초 안에 프로세스가 예고 없이 종료된다.
로그는 "CPU 사용률이 임계치를 넘었다"고 말하지만, 두 가지가 동시에 어긋난다:

1. **같은 구간의 실제 CPU는 0~4%대에 머문다** — 세 독립 측정 전부 일치(아래).
2. **죽는 지점이 설정한 100%가 아니라 ~50%대다** — 여러 실행에서 50.85·54.61·56.27·58.95%에서 종료.

즉 "CPU 과점유"라는 현상 자체가 실재하지 않고, 종료를 유발하는 임계치도 `CPU_MAX_OCCUPY`
값이 아니다. 이 리포트의 핵심은 이 두 불일치다.

## 2. Evidence & Logs (증거 자료)

**앱 자체 로그** — Load가 5%에서 시작해 계속 상승, 임계에서 CRITICAL(`evidence/cpu-fake-load-proof.log`):
```
[INFO] [CpuWorker] Current Load: 25.50%
[INFO] [CpuWorker] Current Load: 58.95%
[CRITICAL] [CpuWorker] CPU Threshold Violated! (58.949999999999996%).
```

**세 가지 독립된 실제 CPU 측정으로 동시 대조**(`evidence/cpu-fake-load-proof.log`):

1. `/proc/<pid>/stat`의 utime+stime을 1초 간격으로 직접 델타 — 앱이 "Load 25.50%"라고
   찍은 초에 실측 `0.0%`, "Load 29.83%"인 초에 `3.0%`.
2. `top -b -n1 -p <pid>` — 앱이 "Load: 33.28%"라고 찍은 바로 그 순간 `top`은 `%CPU 0.0`.
3. `monitor.sh`(자체 개발) — 여러 회차 모두 `CPU:0.0%`~`0.4%`.

세 도구 모두 커널의 같은 원본 카운터(프로세스 스케줄링 시간)를 읽으므로 독립적이지만 필연적으로 일치한다.

**임계 경계 스윕**(`evidence/cpu-threshold-sweep.log`) — `CPU_MAX_OCCUPY`를 49·50·51·55·60·100으로
쓸어 생존/사망 경계를 못박았다(MEMORY_LIMIT=512·MT=false로 CPU축만 격리):

| CPU_MAX_OCCUPY | 결과 | 관측 |
|:--:|:--:|--|
| 49 | 생존 | `Peak reached (49.00%)` 반복 진동 |
| 50 | 생존 | `Peak reached (50.00%)` 반복 진동 |
| 51 | 사망 | `Threshold Violated! (51.00%)` → SIGTERM |
| 55·60·100 | 사망 | 50 넘긴 첫 샘플(53~55%대)에서 SIGTERM |

**[보강 · 표준 동적 관측(디버깅)]** `strace -f`로 종료 순간을 포착(`evidence/cpu-selfkill-strace.log`):
```
tgkill(100520, 100520, SIGTERM) = 0
+++ killed by SIGTERM +++
```
호출자 PID == 대상 PID → 자가종료. 메모리 케이스(SIGKILL)와 달리 여긴 SIGTERM이다.
*이는 스펙 필수요건(top/ps 캡처) 밖의 확인용이며, 아래 결론은 블랙박스 증거만으로 성립한다.*

## 3. Root Cause Analysis (원인 분석)

세 겹으로 확정된 구조다.

**(a) "Current Load %"는 실제 CPU가 아니라 가짜 카운터다.** 프로세스가 실제 계산(busy loop)으로
CPU를 점유하는 게 아니라, 짧은 `sleep` 사이에 내부 변수를 증가시켜 로그에 찍는다. 그래서
커널이 관측하는 프로세스 CPU 시간(utime+stime)은 거의 늘지 않는다(3중 실측 0~4%).

**(b) 임계치가 둘이고, 노브와 킬라인이 분리돼 있다.**
- **쿨다운 상한 = `CPU_MAX_OCCUPY`(가변):** 카운터가 이 값에 닿으면 `Peak reached (cap%). Starting
  cooldown...`으로 클램프되고 5%까지 내려갔다가 다시 상승(진동).
- **킬라인 ≈ 50%(고정, 노브와 무관):** 카운터가 50을 넘는 첫 샘플에서 `CPU Threshold Violated!` →
  SIGTERM 자가종료. `CPU_MAX_OCCUPY=100`이어도 100이 아니라 ~50%대에서 죽는 이유가 이것이다.
- **생존 경계 = `CPU_MAX_OCCUPY ≤ 50`.** 상한이 50 이하면 카운터가 킬라인을 영영 못 넘어 생존;
  51 이상이면 상한으로 오르는 길에 50을 밟고 죽는다.

**(c) 앱이 이 경계를 자기 입으로 신고한다.** 부팅 리소스체크에서 `CPU_MAX_OCCUPY ≤ 50`이면
`[ CPU ] Limit: N% [ OK ]`, `≥ 51`이면 `[ WARNING: Recommend Under 50% ]`로 플래그가 정확히
50/51에서 뒤집힌다 — 행동상의 킬 경계와 앱의 자기 권고가 같은 50을 가리킨다.

**관련 OS 동작 원리**: 실제 프로덕션 Watchdog는 `/proc/<pid>/stat`이나 cgroup `cpu.stat` 같은
커널 실측을 근거로 판단한다. 이 앱은 그 판단 근거를 자체 카운터로 대체해, 관측 대상(진짜
CPU)과 판단 근거(가짜 카운터)를 분리해뒀다. 종료 자체는 진짜 SIGTERM이지만, 그 종료를
유발한 "과점유"는 관측 가능한 어떤 방법으로도 재현되지 않는다.

**메모리 케이스와의 차이**: 메모리 케이스는 실제 RSS가 진짜로 올랐고(관측 가능한 현상은 실재),
"회수 불가능한 leak인가"가 논점이었다. CPU 케이스는 관측 가능한 현상(과점유) 자체가 애초에
발생하지 않는다.

**노브의 함정**: `CPU_MAX_OCCUPY=100`은 "100%까지 허용"처럼 읽히지만 킬라인이 별도 고정 50이라,
100으로 둬도 50%에서 죽는다. 노브가 킬 임계를 제어하지 않는다는 점이 설계상의 혼동 지점이다.

## 4. Workaround & Verification (조치 및 검증)

**조치**: `CPU_MAX_OCCUPY`를 100 → 50으로 하향(= 쿨다운 상한을 고정 킬라인 이하로 내림).

전용 격리 실행으로 확인한 Before/After(`evidence/cpu-maxoccupy-before-after.log`):

| CPU_MAX_OCCUPY | 관측 | 결과 |
|:--:|--|:--:|
| **100 (Before)** | Load 5→56.27%, `Threshold Violated!` → SIGTERM, ~37s | 사망 (exit 143) |
| **50 (After)** | `Peak reached (50.00%)` → cooldown, 50↘19% 진동 | 생존 (exit 124, 관찰창 내내) |
| 10 (대조) | `Peak reached (10.00%)` 반복 진동 | 생존 |

경계 스윕도 일치한다 — 49·50 생존 / 51·55·60·100 사망(`evidence/cpu-threshold-sweep.log`).

**근본적 해결 제안**: 임계값 튜닝은 증상 회피다. Watchdog의 판단 근거를 자체 카운터가 아니라
`/proc/self/stat` 등 실제 커널 CPU 시간으로 바꿔야 "진짜 과점유"에 반응하는 정책이 된다. 더해서,
킬라인이 `CPU_MAX_OCCUPY`와 분리돼 고정 50인 점은 설정을 오해하게 만들므로, 킬 임계를 노브에
연동하거나 최소한 부팅 시 실제 킬라인(50%)을 명시해야 한다.
