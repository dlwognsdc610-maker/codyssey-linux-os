# Codyssey

코디세이(이노베이션 아카데미 AI 올인원 과정) 개별 과제 모음.

- [`b1-1-agent-monitor/`](b1-1-agent-monitor/) — B1-1 시스템 관제 자동화 스크립트. 배포 앱을 실제 구동·관찰(동적 분석)하고(`agent-app-analysis.md`), 그 결과 위에 헬스체크·자원 모니터링·로그 회전을 하는 `monitor.sh`를 구현했다.
- [`linux-troubleshooting/`](linux-troubleshooting/) — 리눅스 프로세스/리소스 트러블슈팅. `agent-leak-app`의 OOM·CPU 과점유·Deadlock을 monitor.sh·ps·top 등 표준 도구만으로 블랙박스 진단해 GitHub Issue 3건을 작성한다. **디컴파일·리버스 엔지니어링 금지 — 스펙에 명시.**
