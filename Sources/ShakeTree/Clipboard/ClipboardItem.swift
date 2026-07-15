import AppKit

struct ClipboardItem: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case text
        case image
        case file  // Finder에서 복사한 파일 경로들 (개행 구분)
    }

    let id: Int64
    let kind: Kind
    let text: String?      // text/file 내용
    let imageData: Data?   // PNG
    let createdAt: Date
    var pinned: Bool

    var previewLine: String {
        switch kind {
        case .text, .file:
            let line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            return line.count > 120 ? String(line.prefix(120)) + "…" : line
        case .image:
            return "이미지"
        }
    }
}
