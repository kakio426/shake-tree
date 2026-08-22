import AppKit
import SwiftUI

/// 모든 커스텀 뷰가 공유하는 디자인 토큰 — 치수·타입 스케일·색 판정이 한 곳에 모여
/// 있어서 뷰끼리 어긋나는 일이 없다. 예전엔 폰트 크기 6종, 색 판정 3곳, 패딩이
/// 뷰마다 제각각이었다.
@MainActor
enum Theme {
    // MARK: 치수

    /// 패널(드롭다운·히스토리) 공통 폭 기준. 메인 패널이 이 값을 쓴다.
    static let panelWidth: CGFloat = 320
    static let cornerRadius: CGFloat = 12
    static let horizontalPadding: CGFloat = 10
    /// 섹션 위아래 여백 — 모든 섹션이 같은 리듬을 쓴다.
    static let blockPadding: CGFloat = 10
    /// 섹션 안 행 간격.
    static let rowSpacing: CGFloat = 8
    /// 상태 행의 아이콘+라벨 열 폭 (들여쓰기에도 재사용).
    static let labelWidth: CGFloat = 56
    /// 상태 행의 오른쪽 수치 최소 폭 — 자릿수 변화에도 흔들리지 않게.
    static let detailWidth: CGFloat = 74
    static let columnSpacing: CGFloat = 12
    /// AI 사용량 2열 배치에서 한 칸의 폭.
    static var columnWidth: CGFloat { (panelWidth - horizontalPadding * 2 - columnSpacing) / 2 }

    // MARK: 타입 스케일

    static let body = Font.system(size: 12)
    static let label = Font.system(size: 12, weight: .medium)
    static let cardTitle = Font.system(size: 12, weight: .semibold)
    /// 큰 수치 — 반올림 디자인 + 고정폭 숫자로 자릿수 변화에도 출렁이지 않게.
    static let number = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
    static let subnumber = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()
    static let caption = Font.system(size: 10)
    static let captionStrong = Font.system(size: 10, weight: .semibold).monospacedDigit()
    static let chipFont = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 9)
    static let microDigit = Font.system(size: 9).monospacedDigit()

    // MARK: 상태 색 — 뷰와 아이콘이 한 곳에서만 갈라져 나간다

    static func color(for level: UsageLevel) -> Color {
        switch level {
        case .critical: .red
        case .warning: .orange
        case .normal: .primary
        }
    }

    /// 메뉴바 나무 아이콘용. nil이면 평소 흑백.
    static func warningColor(for level: UsageLevel) -> NSColor? {
        switch level {
        case .critical: .systemRed
        case .warning: .systemOrange
        case .normal: nil
        }
    }

    /// 남은 비율 기준 게이지 색 — 적게 남을수록 위험.
    static func gaugeColor(remainingPercent remaining: Double) -> Color {
        switch remaining {
        case ..<10: .red
        case ..<30: .orange
        default: .green
        }
    }

    // MARK: 포맷

    static func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// 남은 퍼센트(0~100)를 "42% 남음" 형태로.
    static func remainingText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))% 남음"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func clockText(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }
}
