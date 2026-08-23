import SwiftUI

/// 運動連鎖の解析結果を表示する。DiagnosisView に差し込んで使う。
///
/// **これは処方ではありません。**指標の妥当性が未検証のため、
/// 良い・悪いの判定は出さず、観測された数値と参考レンジを並べるに留める。
struct SwingChainSection: View {

    let result: SwingAnalysis.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("振りの分析（参考）")
                .font(.headline)

            Text("キックは股関節・膝・足首の連動動作です。体幹に近い関節から順に加速し、ボールに当たる瞬間に先端が最速になるのが理想とされます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            chainTimeline

            VStack(spacing: 0) {
                if let thigh = result.thighPeak {
                    row("大腿の回転（股関節）", String(format: "%.0f °/s", thigh.degreesPerSecond),
                        note: String(format: "%+d ms", thigh.offsetMs))
                    Divider()
                }
                if let shank = result.shankPeak {
                    row("下腿の回転", String(format: "%.0f °/s", shank.degreesPerSecond),
                        note: String(format: "%+d ms", shank.offsetMs))
                    Divider()
                }
                if let lag = result.chainLagMs {
                    row("連鎖の時間差", String(format: "%+d ms", lag),
                        note: result.isProximalToDistal == true ? "体幹側が先行" : "順序が逆または同時")
                    Divider()
                }
                if let knee = result.kneeAngleAtCrossing {
                    row("ボール位置での膝角", String(format: "%.0f°", knee),
                        note: result.kneeExtensionUntilCrossing.map {
                            String(format: "最深から %+.0f°", $0)
                        } ?? "")
                    Divider()
                }
                if let efficiency = result.velocityEfficiency {
                    row("最速をボールに合わせられた割合",
                        String(format: "%.0f%%", efficiency * 100),
                        note: "参考: 実測で大人 94〜97%",
                        emphasize: true)
                }
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))

            Text("ボール位置は、蹴り足が軸足を追い越す瞬間として推定しています。基準値は未確定のため判定は行いません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 大腿ピーク → 下腿ピーク → ボール位置 の時間関係を1本の帯で示す。
    private var chainTimeline: some View {
        let marks: [(String, Int, Color)] = [
            ("膝最深", 0, .secondary),
            result.thighPeak.map { ("大腿", $0.offsetMs, Color.orange) } ?? ("", 0, .clear),
            result.shankPeak.map { ("下腿", $0.offsetMs, Color.blue) } ?? ("", 0, .clear),
            result.crossingOffsetMs.map { ("ボール", $0, Color.green) } ?? ("", 0, .clear),
        ].filter { !$0.0.isEmpty }

        let lower = min(marks.map(\.1).min() ?? 0, -30)
        let upper = max(marks.map(\.1).max() ?? 60, 60)

        return GeometryReader { geometry in
            let width = geometry.size.width
            let span = Double(upper - lower)

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 6)
                    .offset(y: 20)

                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    let x = CGFloat((Double(mark.1 - lower)) / span) * width

                    VStack(spacing: 3) {
                        Text(mark.0)
                            .font(.caption2.bold())
                            .foregroundStyle(mark.2)
                        Circle()
                            .fill(mark.2)
                            .frame(width: 9, height: 9)
                        Text("\(mark.1)")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 60)
                    .offset(x: min(max(x - 30, 0), width - 60))
                }
            }
        }
        .frame(height: 52)
    }

    private func row(
        _ label: String,
        _ value: String,
        note: String = "",
        emphasize: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(emphasize ? .callout.bold().monospacedDigit() : .callout.monospacedDigit())
                if !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
