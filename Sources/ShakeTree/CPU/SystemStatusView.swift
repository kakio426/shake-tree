import SwiftUI

/// 시스템 상태 섹션 본문. CPU/RAM은 시간에 따라 변하는 활동량이라 미니 그래프
/// (sparkline)로, 디스크는 "얼마나 찼나"라는 정적인 용량이라 채움 막대(meter)로
/// 보여준다. 셋 다 평소엔 단색이고, 위험 수준일 때만 색을 입힌다 — 아래 AI 사용량의
/// 상시 색상 게이지와 구분된다.
/// (RAM/디스크는 평소에도 높게 유지되는 게 정상이라 CPU보다 높은 경고 기준선을 쓴다.)
struct SystemStatusView: View, Equatable {
    let snapshot: SystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowSpacing) {
            graphRow(
                icon: "cpu", label: "CPU", history: snapshot.cpuHistory, color: .primary,
                detail: Theme.percentText(snapshot.cpuFraction), detailColor: .primary)
            // RAM은 두 줄: 사용량 그래프 + 압축/스왑 보조 줄. 램이 꽉 찬 맥에서는
            // 사용량 GB가 천장에 붙어 거의 안 움직이는 게 정상이라, 실제로 상태를
            // 알려주는 압축·스왑을 바로 아래 붙여둔다.
            VStack(alignment: .leading, spacing: 1) {
                graphRow(
                    icon: "memorychip", label: "RAM", history: snapshot.memHistory,
                    color: ramColor,
                    detail: gbText(snapshot.memUsedGB, snapshot.memTotalGB), detailColor: ramColor)
                memoryDetailRow()
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    rowLabel(icon: "internaldrive", text: "저장")
                    storageMeter.frame(height: 6).frame(height: 22)
                    detailText(gbText(snapshot.diskUsedGB, snapshot.diskTotalGB), color: diskColor)
                }
                if snapshot.diskTotalGB > 0 {
                    HStack {
                        Text(String(format: "파일·시스템 %.1fGB", snapshot.storage.fileSystemGB))
                        Spacer(minLength: 4)
                        Text(String(format: "스왑 파일 %.1fGB", snapshot.storage.swapGB))
                            .foregroundStyle(.blue)
                    }
                    .font(Theme.caption)
                    Text(String(format: "스왑 사용 %.1f / 확보 %.1fGB", snapshot.swapUsedGB, snapshot.swapAllocatedGB))
                        .font(Theme.microDigit).foregroundStyle(.secondary)
                    Text(String(format: "즉시 여유 %.1fGB · 정리 가능 %.1fGB", snapshot.storage.freeGB, snapshot.storage.reclaimableGB))
                        .font(Theme.microDigit).foregroundStyle(.secondary)
                } else {
                    Text("저장공간 확인 중…").font(Theme.micro).foregroundStyle(.secondary)
                }
            }
            .help("스왑 파일 확보량을 저장 점유량에서 분리합니다. 현재 사용 중인 스왑 페이지와 확보한 파일 크기는 다릅니다. 정리 가능 공간은 파일·시스템에 포함됩니다.")
        }
    }


    /// 총량이 작을수록(=RAM) 소수 한 자리까지 — 17GB짜리를 정수로 반올림하면
    /// 1GB 미만의 변화가 통째로 사라져서 값이 멈춰 있는 것처럼 보인다.
    /// 수백 GB짜리 디스크는 반대로 소수점이 지저분하기만 하므로 정수로 둔다.
    private func gbText(_ used: Double, _ total: Double) -> String {
        total < 100
            ? String(format: "%.1f/%.0fGB", used, total)
            : String(format: "%.0f/%.0fGB", used, total)
    }

    private var ramColor: Color { Theme.color(for: snapshot.memLevel) }
    private var diskColor: Color {
        Theme.color(for: SystemThresholds.diskLevel(snapshot.diskFraction))
    }

    /// 압축 메모리는 항상, 스왑은 실제로 쓰이고 있을 때만 표시 —
    /// 스왑 0인 건 건강한 상태라 굳이 자리를 차지할 이유가 없다.
    private var memoryDetailText: String {
        let parts = [String(format: "압축 %.1fGB", snapshot.memCompressedGB)]

        return parts.joined(separator: "  ·  ")
    }

    private func memoryDetailRow() -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Theme.labelWidth, height: 0)  // 위 행 라벨 폭만큼 들여쓰기
            Text(memoryDetailText)
                .font(Theme.subnumber)
                .foregroundStyle(snapshot.memLevel == .normal ? Color.secondary : ramColor)
            Spacer(minLength: 0)
        }
    }

    // CPU/RAM: 시간 추이 그래프
    private func graphRow(
        icon: String, label: String, history: [Double], color: Color,
        detail: String, detailColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            rowLabel(icon: icon, text: label)
            Sparkline(values: history, color: color)
                .frame(height: 22)
            detailText(detail, color: detailColor)
        }
    }

    // 디스크: 실사용(상태 색) + 정리 가능 영역(옅은 회색)을 한 트랙에 두 색으로.
    // raw 사용량이 왜 Finder보다 크게 보이는지 게이지에서 바로 설명되게 한다.
    private var storageMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                HStack(spacing: 0) {
                    Rectangle().fill(diskColor)
                        .frame(width: proxy.size.width * snapshot.storage.ordinaryFraction)
                    Rectangle().fill(Color.blue)
                        .frame(width: proxy.size.width * snapshot.storage.swapFraction)
                    Rectangle().fill(Color.primary.opacity(0.3))
                        .frame(width: proxy.size.width * snapshot.storage.purgeableFraction)
                }
            }.clipShape(Capsule())
        }
    }

    private func rowLabel(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
            Text(text).font(Theme.label)
        }
        .foregroundStyle(.secondary)
        .frame(width: Theme.labelWidth, alignment: .leading)
    }

    private func detailText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.number)
            .foregroundStyle(color)
            .frame(minWidth: Theme.detailWidth, alignment: .trailing)
    }
}
