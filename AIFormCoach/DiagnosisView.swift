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
                } else if diagnosis.judged.isEmpty {
                    // 判定にかけた指標が1つも無いときに allClearNotice を出すと
                    // 「すべて基準を満たしていた」と嘘をつくことになる。
                    // **この分岐そのものは必ず残すこと。**
                    //
                    // ただし画面の先頭に置くのは「撮り直してください」という
                    // 指示だけにする。「判定していません」は断りであって指示では
                    // ないので、最下部の notJudgedFootnote へ回す。指示より先に
                    // 断りを読ませると、その後の指示が読まれない。
                    if diagnosis.items.isEmpty { notMeasuredNotice }
                } else if diagnosis.priorities.isEmpty {
                    allClearNotice
                } else {
                    ForEach(Array(diagnosis.priorities.enumerated()), id: \.element.id) { index, item in
                        prescriptionCard(item, rank: index + 1)
                    }
                }

                if !diagnosis.acceptable.isEmpty { goodSection }
                if !diagnosis.suppressed.isEmpty { suppressedSection }
                if !diagnosis.referenceOnly.isEmpty { referenceOnlySection }
                if !diagnosis.unmeasured.isEmpty { unmeasuredSection }

                qualitySection

                // 断りは全部読み終えたあと。位置と字の大きさで「本文ではない」
                // ことを示す。
                if diagnosis.quality.canPrescribe,
                   !diagnosis.items.isEmpty,
                   diagnosis.judged.isEmpty {
                    notJudgedFootnote
                }
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

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("バックスイング最深")
                        .font(.caption.bold())
                    Text("\(diagnosis.backswingTimeMs) ms / 膝 \(Int(diagnosis.backswingKneeAngle))°")
                        .font(.caption2.monospacedDigit())
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8))
            }

            Text("動作の局面は膝の角度から特定しています。膝は下腿・大腿という長い骨から計算するため、推定が安定しています。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

                    samplingNote(item)
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

    /// どう測ったかを明示する。中央値なら枚数とばらつきも出す。
    private func samplingNote(_ item: DiagnosisEngine.Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.sampleCount > 1 ? "chart.bar.doc.horizontal" : "camera.metering.spot")
                .font(.caption2)
            if item.sampleCount > 1 {
                Text("\(item.windowStartMs)〜\(item.windowEndMs) ms の \(item.sampleCount) フレームの中央値（ばらつき ±\(String(format: "%.1f", item.spread))\(item.metric.unit)）")
                    .font(.caption2)
            } else {
                Text(item.metric.sampling.explanation)
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
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

    // MARK: - 各種セクション

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

    /// 指標を1つも測れなかったとき。
    ///
    /// 中身は「撮り直してください」という**指示**で、しかもこの画面で他に
    /// できることが無い状態なので、先頭に置いたまま目立たせる。
    private var notMeasuredNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("撮り直してください", systemImage: "info.circle.fill")
                .font(.headline)
            Text("指標を1つも測れなかったため、判定できませんでした。下の「測れなかった指標」を確認して、蹴る方向に対して真横から、全身が映るように撮り直してください。")
                .font(.subheadline)
        }
        .padding(16)
        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 測れてはいるが、基準値が確定している指標が無くて合否を出せないとき。
    ///
    /// **画面の最下部に置くこと。**内容は断りであって指示ではない。先頭に
    /// 見出し付きの箱で置くと、練習の指示より先に「判定していません」を
    /// 読ませることになり、そのあとの指示が読まれなくなる。読み手は小学生。
    ///
    /// 各指標についての同じ断りは referenceOnlySection が計測値のすぐ下で
    /// 述べているので、ここでは画面全体としての断りだけにとどめる。
    private var notJudgedFootnote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("基準値が確定している指標が無いため、この画面では良い・悪いの判定を行っていません。上に出している数値は参考として表示しているものです。")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
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

    /// 撮影条件が満たされず計測値も信頼できない指標。
    private var suppressedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("撮り方を変えると測れる指標", systemImage: "video.badge.ellipsis")
                .font(.headline)
            ForEach(diagnosis.suppressed) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.metric.displayName)
                        .font(.subheadline.bold())
                    if let reason = item.suppression {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = item.metric.coachingNote {
                        Text(note)
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 基準値が未確定の指標。計測値と、一般的な指導ポイントを分けて出す。
    private var referenceOnlySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("参考の数値と共通のポイント")
                .font(.headline)
            ForEach(diagnosis.referenceOnly) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(item.metric.displayName)
                            .font(.subheadline.bold())
                        Spacer()
                        Text(String(format: "%.0f%@", item.measured, item.metric.unit))
                            .font(.subheadline.bold())
                            .monospacedDigit()
                    }
                    // 並び順は 計測値 → 練習 → 断り → 出典 で固定する。
                    // 断りを練習より上に置くと、練習が読まれない。
                    if let note = item.metric.coachingNote {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("みんなに共通のポイント", systemImage: "lightbulb")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                            Text(note)
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("この指標は基準値が未確定のため、良い・悪いの判定はしていません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    provenance(item.metric)
                }
                .padding(14)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var unmeasuredSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("測れなかった指標")
                .font(.headline)
            Text(diagnosis.unmeasured.joined(separator: "、"))
                .font(.subheadline)
            Text("必要なフレーム数が足りなかったか、関節の信頼度が不足していました。")
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
                qualityChip(
                    diagnosis.quality.isSideView ? "真横 ○" : "真横 ✕",
                    String(format: "%.2f", diagnosis.quality.footShankRatio)
                )
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
/// 「これ以上あればよい」型の指標では、閾値から右側すべてが緑になる。
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

                // 中央値の場合、区間内のばらつきを薄く重ねる
                if item.sampleCount > 1, item.spread > 0 {
                    let low = position(item.measured - item.spread, span: span, width: width)
                    let high = position(item.measured + item.spread, span: span, width: width)
                    Capsule()
                        .fill(.primary.opacity(0.25))
                        .frame(width: max(high - low, 2), height: 16)
                        .offset(x: low)
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
