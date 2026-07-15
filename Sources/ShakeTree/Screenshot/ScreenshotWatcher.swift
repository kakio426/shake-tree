import AppKit
import Darwin

/// 스크린샷 저장 폴더를 파일시스템 이벤트로 직접 감시해서 새 스크린샷을 즉시 감지하고
/// 클립보드에 이미지를 올려준다. → 저장(파일)과 즉시 붙여넣기(클립보드)를 매번
/// 전환할 필요가 없어진다.
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

    /// 저장 위치를 바꾼 뒤(setLocationToDownloads) 새 폴더를 감시하도록 다시 건다.
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
            // 파일 쓰기가 아직 끝나지 않았을 수 있으니 살짝 기다렸다가 클립보드로 복사
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Self.copyImageToClipboard(url)
            }
        }
    }

    /// Spotlight 인덱스를 거치지 않고, 파일 자체의 확장 속성을 직접 읽어 즉시 판별.
    private static func isScreenCapture(_ url: URL) -> Bool {
        let attr = "com.apple.metadata:kMDItemIsScreenCapture"
        return getxattr(url.path, attr, nil, 0, 0, 0) > 0
    }

    private static func copyImageToClipboard(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let pngData: Data?
        if url.pathExtension.lowercased() == "png" {
            pngData = data
        } else {
            pngData = NSBitmapImageRep(data: data)?
                .representation(using: .png, properties: [:])
        }
        guard let pngData else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
    }

    // MARK: - 저장 위치 설정

    private func currentDirectory() -> URL {
        if let path = Self.rawScreenshotLocation, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private static var rawScreenshotLocation: String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.screencapture", "location"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var screenshotLocation: String {
        (rawScreenshotLocation?.isEmpty == false) ? rawScreenshotLocation! : "~/Desktop (기본값)"
    }

    /// 스크린샷 저장 위치를 다운로드 폴더로 변경 (메뉴에서 사용자가 직접 실행)
    static func setLocationToDownloads() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.screencapture", "location", downloads.path]
        try? task.run()
        task.waitUntilExit()
    }
}
