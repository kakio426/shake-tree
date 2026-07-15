import AppKit

// 프레임 미리보기 덤프 모드: SHAKETREE_DUMP=<dir>로 실행하면 PNG만 저장하고 종료
if let dumpDir = ProcessInfo.processInfo.environment["SHAKETREE_DUMP"] {
    TreeIcon.dump(to: dumpDir)
    exit(0)
}

// 경고색 미리보기: SHAKETREE_DUMP_WARNING=<dir>
if let dir = ProcessInfo.processInfo.environment["SHAKETREE_DUMP_WARNING"] {
    TreeIcon.dumpWarningColors(to: dir)
    exit(0)
}

// 앱 아이콘(.icns) 소스 PNG 생성 모드: SHAKETREE_APPICON=<파일경로>
if let iconPath = ProcessInfo.processInfo.environment["SHAKETREE_APPICON"] {
    AppIconArt.renderPNG(to: URL(fileURLWithPath: iconPath))
    exit(0)
}

// 외부 트리거: `SHAKETREE_POST=show-panel ShakeTree` 로 실행 중인 앱에 패널 열기 요청
if let post = ProcessInfo.processInfo.environment["SHAKETREE_POST"] {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("dev.yubyeongju.shaketree.\(post)"), object: nil,
        userInfo: nil, deliverImmediately: true)
    // 전달이 데몬으로 플러시되도록 잠깐 런루프를 돌린 뒤 종료
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
