[Analysis] 로그 패턴 분석을 통한 스케줄링 알고리즘 추론

## 1. 로그 관찰 개요

`agent-leak-app`을 `MEMORY_LIMIT>256`(Healthy 시나리오)으로 부팅하면 매번 워커
스레드 Thread-A/B/C의 작업 로그가 고정된 패턴으로 출력된다. 이 시퀀스에서 OS/런타임이
작업을 처리하는 스케줄링 기법을 역추적했다. 완전히 독립된 두 번의 부팅(01:48:39,
01:53:17)에서 순서·간격이 동일하게 재현됐다 — 무작위가 아니라 결정적 알고리즘이다.

## 2. 증거 자료

로그 전문은 `evidence/scheduling-demo.log` 참고. 핵심 발췌:

```
[Thread-A] Task Started. Calculating... (20%)
[Thread-A] Calculating... (40%)
[Thread-A] Preempted. Progress saved at (40%)
[Thread-B] Task Started. Calculating... (20%)
[Thread-B] Calculating... (40%)
[Thread-B] Preempted. Progress saved at (40%)
[Thread-C] Task Started. Calculating... (20%)
[Thread-C] Calculating... (40%)
[Thread-C] Preempted. Progress saved at (40%)
[Thread-A] Resumed. Calculating... (60%)
[Thread-A] Calculating... (80%)
[Thread-A] Preempted. Progress saved at (80%)
[Thread-B] Resumed. Calculating... (60%)
...
```

타임스탬프 분석: 각 단계(Started/Calculating/Preempted/Resumed) 사이 간격이
정확히 50~51ms로 균일하다. A가 20%→40%(2 slice)를 채우면 무조건 B로, B가 채우면
무조건 C로 넘어가고, 한 바퀴(A→B→C) 돈 뒤에야 다시 A로 돌아온다.

## 3. 패턴 분석 및 결론

- **순차 처리(FCFS) 아님**: Thread-A가 100% 완료되기 전에(40%에서) Thread-B가
  실행을 시작했다 — 먼저 온 작업을 끝까지 처리하는 방식이 아니다.
- **우선순위 스케줄링 아님**: A/B/C 중 특정 스레드가 더 자주, 더 길게, 혹은 더 먼저
  실행되는 경향이 전혀 없다. 매 턴 정확히 40%(=20% slice ×2)씩 균등하게 진행하고 넘어간다.
- **입도가 고정**: slice(=20% 진행) 하나가 50ms 전후로 균일하고, 한 턴은 2 slice(≈100ms)로
  일정하다 — 작업 내용과 무관하게 정해진 만큼만 CPU(또는 실행 기회)를 쓰고 반납한다.
- **최종 결론**: 각 스레드가 정해진 시간 할당량(한 턴 2 slice, ≈100ms)만큼만 실행되고 강제로
  다음 스레드에 순서를 넘기는 **라운드 로빈(Round-Robin)** 스케줄링으로 추론된다.

## 4. 장단점 및 적합한 아키텍처

**장점**: 모든 작업이 균등하게 실행 기회를 얻어 특정 작업의 기아(starvation) 상태가
없다. 응답 시간 예측이 쉽다(slice 수 × 할당량으로 대략적 대기시간 계산 가능).

**단점**: 작업 길이가 제각각이면 짧은 작업도 긴 작업과 같은 대기를 거쳐야 해
평균 처리시간(turnaround time)이 손해를 볼 수 있다. 컨텍스트 스위칭 비용이
slice 크기에 반비례해 커진다(여기처럼 50ms 단위로 자주 끊으면 스위칭 오버헤드가
누적된다).

**적합한 서비스**: 실시간 응답이 중요한 대화형 시스템(웹 서버의 요청 처리, 채팅
서버 등) — 모든 클라이언트가 "적당히 빨리" 응답받는 게 "누군가는 즉시, 누군가는
영원히 기다림"보다 중요한 경우. 반대로 처리량이 핵심인 배치 서버(대용량 데이터
정렬·컴파일 파이프라인)에는 slice 전환 오버헤드가 순수 낭비이므로 FCFS나
우선순위 기반이 더 적합하다.
