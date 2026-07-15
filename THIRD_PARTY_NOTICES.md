# 서드파티 고지 (Third-Party Notices)

## codexbar-cli (`vendor/codexbar-cli`)

이 저장소는 [steipete/CodexBar](https://github.com/steipete/CodexBar)의 번들 CLI 실행 파일
(`Contents/Helpers/CodexBarCLI`)을 `vendor/codexbar-cli`로 그대로 포함하고 있습니다.
Codex·Claude 사용량 조회에 쓰이며, 원본 서명을 유지한 채 재배포합니다.

This repository vendors the bundled CLI executable from
[steipete/CodexBar](https://github.com/steipete/CodexBar) (`Contents/Helpers/CodexBarCLI`),
included as `vendor/codexbar-cli`, used to fetch Codex/Claude usage data. Its original
code signature is preserved.

라이선스: MIT (전문은 [`vendor/CODEXBAR_LICENSE.txt`](vendor/CODEXBAR_LICENSE.txt) 참고)
License: MIT (see [`vendor/CODEXBAR_LICENSE.txt`](vendor/CODEXBAR_LICENSE.txt) for full text)

```
MIT License
Copyright (c) 2026 Peter Steinberger
```

## Maccy (설계 참고, 코드 미사용 / design reference only, no code copied)

클립보드 감시 방식(폴링 주기, `org.nspasteboard.*` 비공개 타입 처리)은
[p0deje/Maccy](https://github.com/p0deje/Maccy) (MIT)의 구현 방식을 참고했습니다.
코드를 그대로 가져다 쓰지는 않았습니다.

The clipboard-watching approach (polling interval, handling of `org.nspasteboard.*`
concealed types) was inspired by [p0deje/Maccy](https://github.com/p0deje/Maccy) (MIT).
No code was copied verbatim.
