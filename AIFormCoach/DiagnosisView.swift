import SwiftUI

/// 診断結果画面。PRD の三段構成を上から順に見せる。
///
///   ① 憧れの参照(言葉)  →  ② 基準値  →  ③ 自分の数値  →  処方
///
/// この並びが画面上でそのまま読めることを設計の目的にしている。
struct DiagnosisView: View {

    let diagnosis: DiagnosisEngine.Diagnosis

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !diagnosis.quality.canPrescribe {
                    lowConfidenceNotice
                } else if diagnosis.priorities.isEmpty {
                    allClearNotice
                } else {
                    ForEach(Array(diagnosis.priorities.enumerated()), id: \.element.id) { index, item in
                        prescriptionCard(item, rank: index + 1)
                    }
                }

                if !diagnosis.acceptable.isEmpty {
                    goodSection
                }

                if !diagnosis.referenceOnly.isEmpty {
                    referenceOnlySection
                }

                if !diagnosis.unmeasured.isEmpty {
                    unmeasuredSection
                }

                qualitySection
            }
            .padding(20)
        }
        .navigationTitle("今日の診断")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - ヘッダ

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(diagnosis.side == .right ? "右足" : "左足")で蹴ったフォームを見ました")
                .font(.title3.bold())

            HStack(spacing: 8) {
                phaseChip(
                    .backswing,
                    timeMs: diagnosis.items.first { $0.metric.phase == .backswing }?.frameTimeMs
                )
                if diagnosis.keyFrames.impact != nil {
                    phaseChip(
                        .impact,
                        timeMs: diagnosis.items.first { $0.metric.phase == .impact }?.frameTimeMs
                    )
                }
            }

            if let speed = diagnosis.keyFrames.peakToeSpeed {
                Text("インパクト時のつま先の速さ \(String(format: "%.1f", speed)) m/s（腰から見た相対速度）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func phaseChip(_ phase: ReferenceDatabase.Phase, timeMs: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phase.rawValue)
                .font(.caption.bold())
            if let timeMs {
                Text("\(timeMs) ms")
                    .font(.caption2.monospacedDigit())
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.tint, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 処方カード（三段構成）

    private func prescriptionCard(
        _ item: DiagnosisEngine.Item,
        rank: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.tint, in: Circle())
                Text(item.metric.displayName)
                    .font(.headline)
                Spacer()
                Text(item.metric.phase.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ① 憧れの参照(言葉)
            tierBlock(label: "お手本はこう", accent: .orange) {
                Text(item.metric.aspiration)
                    .font(.subheadline)
            }

            // ② 基準値 と ③ 自分の数値
            tierBlock(label: "いまの数値", accent: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", item.measured))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(item.metric.unit)
                            .font(.title3)
                        Spacer()
                        if let tolerance = item.metric.tolerance {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("目標")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(tolerance.describe(unit: item.metric.unit))
                                    .font(.callout.bold())
                                    .monospacedDigit()
                            }
                        }
                    }

                    RangeGauge(item: item)

                    if let target = item.target {
                        Text("目標まで \(String(format: "%.0f", abs(item.measured - target)))\(item.metric.unit)")
                            .font(.footnote.bold())
                            .foregroundStyle(.orange)
                    }
                }
            }

            // 処方
            if let correction = item.correction {
                tierBlock(label: "なぜ直すのか", accent: .secondary) {
                    Text(correction.reason)
                        .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("今日のドリル", systemImage: "figure.run")
                        .font(.subheadline.bold())
                    Text(correction.drillTitle)
                        .font(.headline)
                    Text(correction.drillDetail)
                        .font(.subheadline)
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("合格ライン：\(correction.passLine)")
                            .font(.subheadline.bold())
                    }
                }
                .padding(14)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            provenance(item.metric)
        }
        .padding(18)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
    }

    private func tierBlock<Content: View>(
        label: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 基準値の出典と確度。監修の議論をするために必ず見せる。
    private func provenance(_ metric: ReferenceDatabase.Metric) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: metric.confidence == .supervised ? "book.closed" : "exclamationmark.triangle")
                .font(.caption2)
            Text(
                metric.source.isEmpty
                    ? "基準値の根拠：\(metric.confidence.rawValue)"
                    : "\(metric.confidence.rawValue)／\(metric.source)"
            )
            .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 各種の注意書き

    private var lowConfidenceNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("今回は処方を控えます", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("計測の信頼度が足りないため、間違ったアドバイスをしないよう診断を出していません。明るい場所で、全身が映るように撮り直してください。")
                .font(.subheadline)
        }
        .padding(16)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private var allClearNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("直すところが見つかりません", systemImage: "hand.thumbsup.fill")
                .font(.headline)
            Text("測れた指標はすべて基準を満たしていました。同じフォームを繰り返せるか、もう何本か撮って確かめてみましょう。")
                .font(.subheadline)
        }
        .padding(16)
        .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private var goodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("できていたこと")
                .font(.headline)
            ForEach(diagnosis.acceptable) { item in
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(item.metric.displayName)
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f%@", item.measured, item.metric.unit))
                        .font(.subheadline.bold())
                        .monospacedDigit()
                }
            }
        }
    }

    private var referenceOnlySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参考の数値")
                .font(.headline)
            Text("基準値が未確定のため、計測値のみ表示しています。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(diagnosis.referenceOnly) { item in
                HStack {
                    Text(item.metric.displayName)
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f%@", item.measured, item.metric.unit))
                        .font(.subheadline.bold())
                        .monospacedDigit()
                }
            }
        }
    }

    private var unmeasuredSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("測れなかった指標")
                .font(.headline)
            Text(diagnosis.unmeasured.joined(separator: "、"))
                .font(.subheadline)
            Text("その局面のフレームを特定できなかったか、関節の信頼度が足りませんでした。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("計測の品質")
                .font(.headline)

            HStack {
                qualityChip("fps", String(format: "%.0f", diagnosis.quality.fps))
                qualityChip("検出信頼度", String(format: "%.2f", diagnosis.quality.confidence))
                qualityChip("膝角の変化", String(format: "%.0f°/f", diagnosis.quality.maxKneeDeltaPerFrame))
            }

            ForEach(diagnosis.quality.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text(warning)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func qualityChip(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - ゲージ

/// 合格範囲と自分の数値の関係を1本のバーで見せる。
/// 「これ以上あればよい」型の指標では、上限側がすべて緑になる。
private struct RangeGauge: View {
    let item: DiagnosisEngine.Item

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let display = item.metric.displayRange
            let span = display.upperBound - display.lowerBound

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 10)

                if let tolerance = item.metric.tolerance {
                    let acceptable = tolerance.acceptableSpan(in: display)
                    let start = position(acceptable.lowerBound, span: span, width: width)
                    let end = position(acceptable.upperBound, span: span, width: width)
                    Capsule()
                        .fill(.green.opacity(0.5))
                        .frame(width: max(end - start, 4), height: 10)
                        .offset(x: start)
                }

                Capsule()
                    .fill(item.isAcceptable ? Color.green : Color.orange)
                    .frame(width: 4, height: 22)
                    .offset(x: position(item.measured, span: span, width: width) - 2)
            }
            .frame(height: 22)
        }
        .frame(height: 22)
    }

    private func position(_ value: Double, span: Double, width: CGFloat) -> CGFloat {
        guard span > 0 else { return 0 }
        let ratio = (value - item.metric.displayRange.lowerBound) / span
        return CGFloat(min(max(ratio, 0), 1)) * width
    }
}
