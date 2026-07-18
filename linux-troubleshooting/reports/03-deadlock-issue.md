[Bug] MULTI_THREAD_ENABLE=true에서 순환 대기(circular wait)로 인한 영구 무응답

## 1. Description (현상 설명)

`MULTI_THREAD_ENABLE=true`로 실행하면 부팅 6초 후 두 워커 스레드가 각각 자원을
확보한 뒤 상대방이 쥔 자원을 요구하며 동시에 멈춘다. 프로세스는 종료되지 않고
PID·포트 모두 살아있지만, 이후 40초(관찰 상한)까지 로그 출력이 완전히 끊긴다.
`MULTI_THREAD_ENABLE=false`로는 이 세션에서 진행한 다른 모든 테스트(OOM·CPU 케이스
전부)가 단 한 번도 이 상태에 빠지지 않았다.

## 2. Evidence & Logs (증거 자료)

**PID 존재 확인** (`ps -ef | grep agent`, `evidence/deadlock-log.log`):
```
ljh  103179  103177  0  02:27 ?  00:00:00 ./agent-leak-app-x86
```

**앱 로그** — 정확한 순환 구조:
```
[Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
[Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
[Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
[Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
[Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
[Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```
Thread-1이 A를 쥐고 B를 기다림, Thread-2가 B를 쥐고 A를 기다림.

**CPU/메모리 변화 정체 증거** (`ps -eLf`, `evidence/deadlock-kernel-proof.log`) — 스레드
3개(main+worker 2개) 전부 CPU 0%, 8초 간격 재확인에도 동일.

**커널 레벨 확정 증거** — `/proc/<tid>/wchan`(애플리케이션이 조작 불가능한 커널
스케줄러 상태)이 세 스레드 모두 `futex_do_wait`, 8초 뒤에도 불변. 여기서 멈춰
`sleep()`(다른 syscall·다른 wchan을 씀)이 아님을 구분했다.

**[보강 · 표준 동적 관측(디버깅), 필수요건 밖]** 더 나아가 `strace -f -e trace=futex`로 futex
syscall 자체를 처음부터 추적해, 로그의 "BLOCKED" 시각과 1ms 이내로 일치하는 순간에
**서로 다른 두 개의 futex 주소**에 각 스레드가 새로 진입해 영구 정지하는 걸 직접 확인했다:
```
futex(0x407050d0, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, ...) <unfinished ...>
futex(0x4070e260, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, ...) <unfinished ...>
```
두 주소가 다르다 — 단일 더미 대기가 아니라 서로 다른 락 객체 두 개가 실재한다.
(ps -ef PID·`ps -eLf` 정체·`/proc/<tid>/wchan`·마지막 BLOCKED 로그로 필수요건은 이미
충족되고, 이 strace는 "락이 둘"임을 못박는 보강이다.)

## 3. Root Cause Analysis (원인 분석)

전형적인 순환 대기(circular wait) 데드락이다. 데드락의 4대 조건이 모두 성립한다:

- **상호 배제(Mutual Exclusion)**: `Shared_Memory_A`·`Socket_Pool_B` 각각 한 스레드만 보유.
- **점유 대기(Hold and Wait)**: 각 스레드가 자기 락을 쥔 채로 상대방 락을 요구.
- **비선점(No Preemption)**: 강제로 락을 빼앗아 넘겨주는 메커니즘이 없다(40초 넘게 불변).
- **순환 대기(Circular Wait)**: Thread-1 → B(Thread-2가 보유) → A(Thread-1이 보유) → 순환.

**관련 OS 동작 원리**: 커널은 futex 기반 락에서 데드락을 자동으로 탐지·해소하지
않는다 — 스케줄러 입장에서는 "실행할 게 없어 잠든 스레드"와 "데드락으로 영원히
못 깨는 스레드"를 구분할 방법이 없다(둘 다 `futex_do_wait`로 동일하게 보인다).
그래서 애플리케이션이 락 획득 순서를 강제하거나(항상 A→B 순서로만 잠그기), 타임아웃을
두거나, 데드락 탐지 알고리즘(자원 할당 그래프 순회)을 직접 구현하지 않는 한 영원히
풀리지 않는다.

## 4. Workaround & Verification (조치 및 검증)

**조치**: `MULTI_THREAD_ENABLE`을 true → false로 변경.

**Before**: `MULTI_THREAD_ENABLE=true` — 6초 만에 두 스레드 모두 `BLOCKED`, 40초
관찰 동안 무응답 지속(`futex_do_wait` 불변).

**After**: `MULTI_THREAD_ENABLE=false` — 데드락 발생 없이 정상 동작. (이 세션의
OOM·CPU 테스트가 전부 이 설정으로 진행됐고, 매번 정상적으로 크래시하거나 생존했다 —
한 번도 무응답 상태에 빠지지 않았다.)

**근본적 해결 제안**: `MULTI_THREAD_ENABLE=false`는 회피일 뿐 근본 해결이 아니다(동시성
자체를 포기하는 것이므로). 근본적으로는 두 자원에 대한 락 획득 순서를 모든 스레드가
동일하게 강제하거나(예: 항상 A를 먼저 잠그고 B를 나중에), `Lock.acquire(timeout=N)`으로
타임아웃을 걸어 실패 시 이미 쥔 락을 풀고 재시도하는 방식으로 순환 대기 조건 자체를
깨야 한다.
