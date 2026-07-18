import AppKit
import Darwin

/// 스크린샷 처리 방식.
enum ScreenshotMode: String {
    case both  // 파일(다운로드)로 저장 + 클립보드에도 복사
    case clipboardOnly  // 파일 저장 없이 클립보드로만 (macOS 네이티브, 즉시)

    static var current: ScreenshotMode {
        ScreenshotMode(rawValue: UserDefaults.standard.string(forKey: "screenshotMode") ?? "")
            ?? .both
    }
}

/// 스크린샷 저장 폴더를 파일시스템 이벤트로 직접 감시해서 새 스크린샷을 즉시 감지하고
/// 클립보드에 이미지를 올려준다. → 저장(파일)과 즉시 붙여넣기(클립보드)를 매번
/// 전환할 필요가 없어진다. (both 모드에서만 사용. clipboardOnly 모드는 macOS가
/// target=clipboard로 직접 클립보드에 넣으므로 이 감시기가 필요 없다.)
///
/// 예전엔 NSMetadataQuery(Spotlight 검색 인덱스)로 감지했는데, 시스템 부하가 높으면
/// mdworker 인덱싱이 몇 초~몇십 초씩 지연될 수 있고, 그 지연된 알림이 뒤늦게 도착하면
/// 그 사이 사용자가 복사해 둔 다른 내용을 스크린샷 이미지로 덮어써버리는 문제가 있었다.
/// 지금은 디렉토리를 커널 이벤트(kqueue)로 직접 감시하고, 새 파일의
/// "com.apple.metadata:kMDItemIsScreenCapture" 확장 속성을 파일에서 바로 읽어
/// 판별한다 — 둘 다 Spotlight 인덱싱을 거치지 않아 지연이 없다.
@MainActor
final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: CInt = -1
    private var knownNames = Set<String>()
    private var watchedDirectory: URL?

    func start() {
        watch(directory: currentDirectory())
    }

    func stop() {
        source?.cancel()
        source = nil
        watchedDirectory = nil
    }

    /// 저장 위치를 바꾼 뒤 새 폴더를 감시하도록 다시 건다.
    func directoryMayHaveChanged() {
        let dir = currentDirectory()
        guard dir != watchedDirectory else { return }
        watch(directory: dir)
    }

    private func watch(directory: URL) {
        source?.cancel()
        source = nil

        watchedDirectory = directory
        knownNames = Set(fileNames(in: directory))

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFD = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        newSource.setEventHandler { [weak self] in
            Task { @MainActor in self?.checkForNewFiles() }
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        source = newSource
    }

    private func fileNames(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func checkForNewFiles() {
        guard let dir = watchedDirectory else { return }
        let current = Set(fileNames(in: dir))
        let added = current.subtracting(knownNames)
        knownNames = current

        for name in added {
            let url = dir.appendingPathComponent(name)
            guard Self.isScreenCapture(url) else { continue }
            scheduleCopy(url)
        }
    }

    /// 최대한 빨리(0.05초) 시도하되, 파일 쓰기가 덜 끝나 이미지를 못 읽으면 짧게 재시도.
    /// 예전엔 무조건 0.2초를 기다렸는데, 그보다 빠르게 반응하면서도 안전하다.
    private func scheduleCopy(_ url: URL, attempt: Int = 0) {
        let delay = attempt == 0 ? 0.05 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if Self.copyImageToClipboard(url) { return }
            if attempt < 4 { self.scheduleCopy(url, attempt: attempt + 1) }
        }
    }

    /// Spotlight 인덱스를 거치지 않고, 파일 자체의 확장 속성을 직접 읽어 즉시 판별.
    private static func isScreenCapture(_ url: URL) -> Bool {
        let attr = "com.apple.metadata:kMDItemIsScreenCapture"
        return getxattr(url.path, attr, nil, 0, 0, 0) > 0
    }

    /// 이미지를 읽어 클립보드에 넣었으면 true. 파일이 아직 덜 써졌으면 false(재시도 대상).
    @discardableResult
    private static func copyImageToClipboard(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        let pngData: Data?
        if url.pathExtension.lowercased() == "png" {
            // 유효한 이미지로 디코드되는지 확인 — 쓰다 만 파일이면 nil
            pngData = NSBitmapImageRep(data: data) != nil ? data : nil
        } else {
            pngData = NSBitmapImageRep(data: data)?
                .representation(using: .png, properties: [:])
        }
        guard let pngData else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        return true
    }

    // MARK: - 모드/저장 위치 설정

    private func currentDirectory() -> URL {
        if let path = Self.rawScreenshotLocation, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private static var rawScreenshotLocation: String? {
        readDefault("location")
    }

    /// 스크린샷 모드에 맞게 macOS `com.apple.screencapture` 설정을 적용한다.
    /// 두 모드 모두 "떠다니는 미리보기 썸네일"을 꺼서(show-thumbnail=false) 캡처 직후
    /// 곧바로 파일 쓰기/클립보드 반영이 되도록 한다 — 썸네일이 켜져 있으면 캡처가
    /// 몇 초간 지연되어 클립보드 복사가 한참 뒤에 되는 것처럼 느껴진다.
    static func applyMode(_ mode: ScreenshotMode) {
        writeDefault("show-thumbnail", "-bool", "false")
        switch mode {
        case .both:
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask)[0]
            writeDefault("target", "file")
            writeDefault("location", downloads.path)
        case .clipboardOnly:
            writeDefault("target", "clipboard")
        }
    }

    private static func readDefault(_ key: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.screencapture", key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeDefault(_ args: String...) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.screencapture"] + args
        try? task.run()
        task.waitUntilExit()
    }
}
