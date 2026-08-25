import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// 스크린샷 처리 방식.
enum ScreenshotMode: String {
    case both  // 파일(다운로드)로 저장 + 클립보드에도 복사
    case clipboardOnly  // 파일 저장 없이 클립보드로만 (macOS 네이티브, 즉시)

    static var current: ScreenshotMode {
        ScreenshotMode(rawValue: UserDefaults.standard.string(forKey: "screenshotMode") ?? "")
            ?? .both
    }
}

/// 스크린샷 저장 폴더를 kqueue로 감시해 새 스크린샷을 클립보드에도 올린다.
/// 디렉터리 열거·파일 읽기·이미지 변환은 백그라운드에서 하고 NSPasteboard 접근만
/// MainActor에서 수행해 메뉴바 입력과 애니메이션을 막지 않는다.
@MainActor
final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var knownNames = Set<String>()
    private var watchedDirectory: URL?
    private var scanTask: Task<Void, Never>?
    private var rescanRequested = false
    private var copyTasks: [URL: Task<Void, Never>] = [:]
    private var generation = 0

    func start() {
        let directory = currentDirectory()
        guard source == nil || watchedDirectory != directory else { return }
        watch(directory: directory)
    }

    func stop() {
        generation &+= 1
        source?.cancel()
        source = nil
        scanTask?.cancel()
        scanTask = nil
        for task in copyTasks.values { task.cancel() }
        copyTasks.removeAll()
        watchedDirectory = nil
        knownNames.removeAll(keepingCapacity: true)
        rescanRequested = false
    }

    /// 저장 위치를 바꾼 뒤 새 폴더를 감시하도록 다시 건다.
    func directoryMayHaveChanged() {
        let directory = currentDirectory()
        guard directory != watchedDirectory else { return }
        watch(directory: directory)
    }

    private func watch(directory: URL) {
        stop()

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        generation &+= 1
        let currentGeneration = generation
        watchedDirectory = directory

        // 기준 스냅샷은 한 번만 잡는다. 이후 kqueue 이벤트마다 수행되는 전체 열거는
        // requestScan이 utility 작업으로 옮긴다.
        knownNames = Set(Self.fileNames(in: directory))

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        newSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration else { return }
                self.requestScan()
            }
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        source = newSource
    }

    /// 이벤트가 몰리면 진행 중인 열거 뒤에 한 번만 더 확인한다.
    private func requestScan() {
        guard scanTask == nil, let directory = watchedDirectory else {
            rescanRequested = true
            return
        }
        rescanRequested = false
        let baseline = knownNames
        let currentGeneration = generation

        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let current = Set(Self.fileNames(in: directory))
                return (current: current, added: current.subtracting(baseline))
            }.value

            guard !Task.isCancelled, let self,
                self.generation == currentGeneration,
                self.watchedDirectory == directory
            else { return }

            self.knownNames = result.current
            self.scanTask = nil
            for name in result.added {
                self.scheduleCopy(directory.appendingPathComponent(name))
            }
            if self.rescanRequested { self.requestScan() }
        }
    }

    /// 최대 0.53초 동안 파일 완성을 기다린다. 그 사이 사용자가 다른 내용을 복사했다면
    /// 늦게 도착한 스크린샷으로 새 클립보드를 덮어쓰지 않는다.
    private func scheduleCopy(_ url: URL) {
        guard copyTasks[url] == nil else { return }
        let currentGeneration = generation
        let expectedChangeCount = NSPasteboard.general.changeCount

        copyTasks[url] = Task { [weak self] in
            for attempt in 0...4 {
                let delay: Duration = attempt == 0 ? .milliseconds(50) : .milliseconds(120)
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }

                let pngData = await Task.detached(priority: .utility) {
                    Self.loadScreenCapturePNG(from: url)
                }.value
                guard let pngData else { continue }
                guard let self, self.generation == currentGeneration else { return }

                self.copyTasks[url] = nil
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount == expectedChangeCount else { return }
                pasteboard.clearContents()
                pasteboard.setData(pngData, forType: .png)
                return
            }
            self?.copyTasks[url] = nil
        }
    }

    private nonisolated static func fileNames(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Spotlight 없이 확장 속성을 확인하고, ImageIO로 완성된 파일만 PNG Data로 만든다.
    private nonisolated static func loadScreenCapturePNG(from url: URL) -> Data? {
        let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
        guard getxattr(url.path, attribute, nil, 0, 0, 0) > 0,
            let data = try? Data(contentsOf: url), !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }

        if url.pathExtension.lowercased() == "png" { return data }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 모드/저장 위치 설정

    private func currentDirectory() -> URL {
        if let path = Self.rawScreenshotLocation, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private static let preferencesAppID = "com.apple.screencapture" as CFString

    private static var rawScreenshotLocation: String? {
        CFPreferencesCopyAppValue("location" as CFString, preferencesAppID) as? String
    }

    /// 별도 `defaults` 프로세스를 띄우고 메인 스레드에서 waitUntilExit하던 경로 대신
    /// 같은 CFPreferences 저장소를 직접 갱신한다.
    static func applyMode(_ mode: ScreenshotMode) {
        CFPreferencesSetAppValue(
            "show-thumbnail" as CFString, kCFBooleanFalse, preferencesAppID)
        switch mode {
        case .both:
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask)[0]
            CFPreferencesSetAppValue(
                "target" as CFString, "file" as CFString, preferencesAppID)
            CFPreferencesSetAppValue(
                "location" as CFString, downloads.path as CFString, preferencesAppID)
        case .clipboardOnly:
            CFPreferencesSetAppValue(
                "target" as CFString, "clipboard" as CFString, preferencesAppID)
        }
        _ = CFPreferencesAppSynchronize(preferencesAppID)
    }
}
