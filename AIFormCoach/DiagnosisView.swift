import SwiftUI

/// 診断結果画面。
///
/// **設計方針**
/// 1ページ目で状態が一目で分かることを優先する。旧実装は解説文が長く、
/// スクロールしないと何が問題か分からなかった。
///
/// 上から:
///   ① 総合の星と一言        … 結論
///   ② パラメータ一覧        … 全指標をバーで並べる（ゲームの能力値のように）
///   ③ 今日のドリル          … やること
///   ④ くわしく（折りたたみ） … 理由・お手本・共通のポイント・出典
///   ⑤ 計測の品質
struct DiagnosisView: View {

    let diagnosis: DiagnosisEngine.Diagnosis

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCard
                parameterList

                if let top = diagnosis.priorities.first, let correction = top.correction {
                    drillCard(correction, metric: top.metric)
                }

                detailsSection
                qualitySection
            }
            .padding(20)
        }
        .navigationTitle("今日の診断")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - ① 総合

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.title3.bold())

            if let top = diagnosis.priorities.first {
                StarRow(filled: stars(for: top) ?? 0)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(top.metric.displayName)
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f%@", top.measured, top.metric.unit))
                        .font(.title2.bold().monospacedDigit())
                    if let target = top.target {
                        Text(String(format: "→ %.0f%@", target, top.metric.unit))
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            } else if !diagnosis.quality.canPrescribe {
                StarRow(filled: 0)
                Text("計測の信頼度が足りないため、判定を控えています。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                StarRow(filled: 5)
                Text("測れた指標はすべて基準の範囲でした。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(summaryTint, in: RoundedRectangle(cornerRadius: 16))
    }

    private var headline: String {
        if !diagnosis.quality.canPrescribe { return "今回は判定を控えます" }
        guard let top = diagnosis.priorities.first else { return "いい形で蹴れています" }
        return top.deviation < 0 ? "もう少し深くたためます" : "たたみが深すぎます"
    }

    private var summaryTint: Color {
        if !diagnosis.quality.canPrescribe { return .orange.opacity(0.15) }
        return diagnosis.priorities.isEmpty ? .green.opacity(0.15) : .blue.opacity(0.12)
    }

    // MARK: - ② パラメータ一覧

    private var parameterList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("パラメータ")
                .font(.headline)

            VStack(spacing: 14) {
                ForEach(orderedItems) { item in
                    ParameterRow(item: item, stars: stars(for: item))
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))

            if !diagnosis.unmeasured.isEmpty {
                Text("測れなかった指標：\(diagnosis.unmeasured.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 処方対象を先、参考値を後に並べる。
    private var orderedItems: [DiagnosisEngine.Item] {
        let prescribable = diagnosis.items.filter { $0.metric.isPrescribable && !$0.isSuppressed }
        let others = diagnosis.items.filter { !$0.metric.isPrescribable || $0.isSuppressed }
        return prescribable.sorted { $0.severity > $1.severity } + others
    }

    // MARK: - ③ ドリル

    private func drillCard(
        _ correction: ReferenceDatabase.Correction,
        metric: ReferenceDatabase.Metric
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("今日のドリル", systemImage: "figure.run")
                .font(.subheadline.bold())
                .foregroundStyle(.green)

            Text(correction.drillTitle)
                .font(.title3.bold())

            Text(correction.drillDetail)
                .font(.subheadline)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(correction.passLine)
                    .font(.subheadline.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - ④ くわしく（折りたたみ）

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(orderedItems) { item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        block("お手本はこう", item.metric.aspiration, tint: .orange)

                        if let correction = item.correction {
                            block("なぜ直すのか", correction.reason, tint: .blue)
                        }
                        if let note = item.metric.coachingNote {
                            block("みんなに共通のポイント", note, tint: .orange)
                        }
                        if let reason = item.suppression {
                            block("この撮影では判定しません", reason, tint: .orange)
                        }

                        samplingNote(item)
                        provenance(item.metric)
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text(item.metric.displayName)
                            .font(.subheadline)
                        Spacer()
                        StatusChip(item: item)
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
    }

    private func block(_ label: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func samplingNote(_ item: DiagnosisEngine.Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.sampleCount > 1 ? "chart.bar.doc.horizontal" : "camera.metering.spot")
            if item.sampleCount > 1 {
                Text("\(item.windowStartMs)〜\(item.windowEndMs) ms の \(item.sampleCount) フレームの中央値（±\(String(format: "%.1f", item.spread))\(item.metric.unit)）")
            } else {
                Text(item.metric.sampling.explanation)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func provenance(_ metric: ReferenceDatabase.Metric) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: metric.confidence == .supervised ? "book.closed" : "exclamationmark.triangle")
            Text(metric.source.isEmpty ? metric.confidence.rawValue : "\(metric.confidence.rawValue)／\(metric.source)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - ⑤ 計測の品質

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("計測の品質")
                .font(.headline)

            HStack(spacing: 8) {
                chip("\(Int(diagnosis.quality.fps))", "fps")
                chip(String(format: "%.2f", diagnosis.quality.confidence), "信頼度")
                chip(diagnosis.quality.isSideView ? "○" : "✕", "真横")
                chip("\(Int(diagnosis.quality.windowHealthyRatio * 100))%", "健全")
            }

            ForEach(diagnosis.quality.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(warning)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ value: String, _ label: String) -> some View {
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

    // MARK: - 星の算出

    /// 基準値からの逸脱を星に変換する。
    /// 5 = 範囲内、4 = 測定誤差程度、以降は逸脱の大きさで下がる。
    private func stars(for item: DiagnosisEngine.Item) -> Int? {
        guard item.metric.isPrescribable, !item.isSuppressed else { return nil }
        let deviation = abs(item.deviation)
        if deviation == 0 { return 5 }
        if deviation <= 5 { return 4 }
        if deviation <= 15 { return 3 }
        if deviation <= 25 { return 2 }
        return 1
    }
}

// MARK: - 星

private struct StarRow: View {
    let filled: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= filled ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(index <= filled ? .yellow : .secondary.opacity(0.4))
            }
        }
        .accessibilityLabel("5段階で \(filled)")
    }
}

// MARK: - パラメータ1行

/// 指標を1行で表す。名前・状態・数値・バー。解説は入れない。
private struct ParameterRow: View {
    let item: DiagnosisEngine.Item
    let stars: Int?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(item.metric.displayName)
                    .font(.subheadline)

                Spacer()

                if let stars {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { index in
                            Image(systemName: index <= stars ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(index <= stars ? .yellow : .secondary.opacity(0.35))
                        }
                    }
                } else {
                    StatusChip(item: item)
                }

                Text(String(format: "%.0f%@", item.measured, item.metric.unit))
                    .font(.callout.bold().monospacedDigit())
                    .frame(width: 54, alignment: .trailing)
            }

            Gauge(item: item)
        }
    }
}

/// 処方対象でない指標の状態表示。
private struct StatusChip: View {
    let item: DiagnosisEngine.Item

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var text: String {
        if item.isSuppressed { return "撮り方" }
        if !item.metric.isPrescribable { return "参考" }
        return item.isAcceptable ? "OK" : "要改善"
    }

    private var color: Color {
        if item.isSuppressed { return .orange }
        if !item.metric.isPrescribable { return .secondary }
        return item.isAcceptable ? .green : .orange
    }
}

// MARK: - バー

private struct Gauge: View {
    let item: DiagnosisEngine.Item

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let display = item.metric.displayRange
            let span = display.upperBound - display.lowerBound

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 8)

                if let tolerance = item.metric.tolerance {
                    let acceptable = tolerance.acceptableSpan(in: display)
                    let start = position(acceptable.lowerBound, span: span, width: width)
                    let end = position(acceptable.upperBound, span: span, width: width)
                    Capsule()
                        .fill(.green.opacity(0.45))
                        .frame(width: max(end - start, 4), height: 8)
                        .offset(x: start)
                }

                Capsule()
                    .fill(markerColor)
                    .frame(width: 4, height: 18)
                    .offset(x: position(item.measured, span: span, width: width) - 2)
            }
            .frame(height: 18)
        }
        .frame(height: 18)
    }

    private var markerColor: Color {
        if item.isSuppressed { return .orange }
        if !item.metric.isPrescribable { return .secondary }
        return item.isAcceptable ? .green : .orange
    }

    private func position(_ value: Double, span: Double, width: CGFloat) -> CGFloat {
        guard span > 0 else { return 0 }
        let ratio = (value - item.metric.displayRange.lowerBound) / span
        return CGFloat(min(max(ratio, 0), 1)) * width
    }
}
