import SwiftUI

/// お手本と自分を比べる画面。
///
/// **なぜ既定を横並びにしたか**
/// 重ね合わせは「同じ瞬間の姿勢」を1枚で比べるのに向くが、動きの流れを
/// 追うには不向きだった。速さや振り幅が違う2本を重ねると常にずれて見え、
/// そのずれが「フォームの差」なのか「タイミングの差」なのか判別できない。
/// 横に並べれば、それぞれの動きを追いながら同じ瞬間を比べられる。
///
/// 重ね合わせは切り替えで使う。気になる瞬間で重ねて詳しく見る想定。
struct ComparisonView: View {

    let result: PoseComparison.Result

    @State private var relativeMs: Double = 0
    /// お手本側の時間をずらす量。自動検出のずれを手で補正する。
    @State private var offsetMs: Double = 0
    @State private var isPlaying = false
    @State private var mode: Mode = .sideBySide

    private enum Mode: String, CaseIterable {
        case sideBySide = "並べる"
        case overlay = "重ねる"
    }

    private let mineColor = Color.green
    private let modelColor = Color.orange

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("表示", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .sideBySide: sideBySideView
                case .overlay: overlayView
                }

                scrubber
                offsetControl
                diffSection

                if !result.cautions.isEmpty { cautionSection }
            }
            .padding(20)
        }
        .navigationTitle("お手本とくらべる")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isPlaying) { await animate() }
    }

    // MARK: - 横並び

    private var sideBySideView: some View {
        HStack(spacing: 10) {
            panel(
                label: result.mine.label,
                color: mineColor,
                pose: result.mine.pose(atRelativeMs: Int(relativeMs)),
                side: result.mine.side
            )
            panel(
                label: result.model.label,
                color: modelColor,
                pose: result.model.pose(atRelativeMs: Int(relativeMs + offsetMs)),
                side: result.model.side
            )
        }
        .frame(height: 320)
    }

    private func panel(
        label: String,
        color: Color,
        pose: PoseComparison.NormalizedPose?,
        side: JointAngles.Side
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                    .font(.caption.bold())
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))

            Canvas { context, size in
                guard let pose else { return }
                // 脚長=1の正規化座標。体の縦幅は約2.2なので余裕を持たせる。
                let scale = size.height / 2.6
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                draw(pose, in: &context, center: center, scale: scale,
                     color: color, lineWidth: 5, opacity: 1, side: side)
            }
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - 重ね合わせ

    private var overlayView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                legendChip(result.mine.label, mineColor)
                legendChip(result.model.label, modelColor)
                Spacer()
            }

            ZStack {
                Canvas { context, size in
                    let scale = size.height / 2.6
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)

                    if let pose = result.model.pose(atRelativeMs: Int(relativeMs + offsetMs)) {
                        draw(pose, in: &context, center: center, scale: scale,
                             color: modelColor, lineWidth: 8, opacity: 0.5,
                             side: result.model.side)
                    }
                    if let pose = result.mine.pose(atRelativeMs: Int(relativeMs)) {
                        draw(pose, in: &context, center: center, scale: scale,
                             color: mineColor, lineWidth: 5, opacity: 1,
                             side: result.mine.side)
                    }
                }
                .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))

                VStack {
                    Spacer()
                    Text("腰の位置と脚の長さを揃えて重ねています")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(height: 320)
    }

    private func legendChip(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption.bold())
        }
    }

    // MARK: - 描画

    private func draw(
        _ pose: PoseComparison.NormalizedPose,
        in context: inout GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        color: Color,
        lineWidth: CGFloat,
        opacity: Double,
        side: JointAngles.Side
    ) {
        func screen(_ joint: PoseJoint) -> CGPoint {
            let p = pose[joint]
            return CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale)
        }

        for (a, b) in PoseJoint.bones {
            guard pose.isVisible(a), pose.isVisible(b) else { continue }
            var path = Path()
            path.move(to: screen(a))
            path.addLine(to: screen(b))
            context.stroke(
                path,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }

        // 蹴り足の関節だけ点で強調する
        for joint in [side.hip, side.knee, side.ankle, side.toe] where pose.isVisible(joint) {
            let p = screen(joint)
            let r = lineWidth * 0.85
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(opacity))
            )
        }
    }

    // MARK: - 時間軸

    private var scrubber: some View {
        VStack(spacing: 6) {
            HStack {
                Text(String(format: "%+d ms", Int(relativeMs)))
                    .font(.callout.bold().monospacedDigit())
                Spacer()
                if Int(relativeMs) == 0 {
                    Text(result.anchorDescription)
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
            }

            Slider(
                value: $relativeMs,
                in: Double(result.sharedRange.lowerBound)...Double(result.sharedRange.upperBound),
                step: 5
            )
            .onChange(of: relativeMs) { _, _ in
                if isPlaying { isPlaying = false }
            }

            HStack(spacing: 10) {
                Button(isPlaying ? "一時停止" : "再生") { isPlaying.toggle() }
                    .buttonStyle(.bordered)
                Button("0msに戻す") { relativeMs = 0; isPlaying = false }
                    .buttonStyle(.bordered)
                Spacer()
            }

            Text("\(result.anchorDescription)を 0ms として2本を揃えています。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// お手本側の時間を手動でずらす。
    /// 自動検出が動作の違いでずれることがあるため、目で合わせられるようにする。
    private var offsetControl: some View {
        VStack(spacing: 4) {
            HStack {
                Text("お手本のタイミング調整")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+d ms", Int(offsetMs)))
                    .font(.caption.monospacedDigit())
                if offsetMs != 0 {
                    Button("戻す") { offsetMs = 0 }
                        .font(.caption)
                }
            }
            Slider(value: $offsetMs, in: -200...200, step: 5)
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 差分

    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("どこが違うか")
                .font(.headline)

            VStack(spacing: 16) {
                ForEach(result.diffs) { diff in
                    DiffRow(diff: diff, mineColor: mineColor, modelColor: modelColor)
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))

            Text("体格の差を消すため、脚の長さを揃えて比べています。数値は参考値です。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var cautionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(result.cautions, id: \.self) { caution in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(caution)
                }
                .font(.caption)
            }
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 再生

    private func animate() async {
        guard isPlaying else { return }
        while isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
            relativeMs += 10
            if relativeMs > Double(result.sharedRange.upperBound) {
                relativeMs = Double(result.sharedRange.lowerBound)
            }
        }
    }
}

// MARK: - 差分1行

private struct DiffRow: View {
    let diff: PoseComparison.MetricDiff
    let mineColor: Color
    let modelColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(diff.metric.displayName)
                    .font(.subheadline)
                Spacer()
                if let delta = diff.delta {
                    Text(String(format: "%+.0f%@", delta, diff.metric.unit))
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(abs(delta) < 5 ? .green : .orange)
                } else {
                    Text("—").font(.callout).foregroundStyle(.secondary)
                }
            }

            bar

            HStack(spacing: 14) {
                value(diff.mine, color: mineColor, label: "自分")
                value(diff.model, color: modelColor, label: "お手本")
                Spacer()
            }

            if let hint = diff.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func value(_ v: Double?, color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(v.map { String(format: "%.0f%@", $0, diff.metric.unit) } ?? "—")
                .font(.caption.bold().monospacedDigit())
        }
    }

    private var bar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let range = diff.metric.displayRange
            let span = range.upperBound - range.lowerBound

            // ローカル関数ではなくクロージャにする。
            // ViewBuilder(結果ビルダー)のクロージャ内でローカル関数を宣言すると、
            // その関数内の guard-return を ViewBuilder 本体からの明示的returnと
            // 誤認識してコンパイルエラーになることがある。クロージャは
            // ViewBuilderの変換対象にならないため発生しない。
            let x: (Double) -> CGFloat = { value in
                guard span > 0 else { return 0 }
                let ratio = (value - range.lowerBound) / span
                return CGFloat(min(max(ratio, 0), 1)) * width
            }

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)

                if let tolerance = diff.metric.tolerance {
                    let span2 = tolerance.acceptableSpan(in: range)
                    Capsule()
                        .fill(.green.opacity(0.35))
                        .frame(width: max(x(span2.upperBound) - x(span2.lowerBound), 3), height: 6)
                        .offset(x: x(span2.lowerBound))
                }
                if let model = diff.model {
                    Capsule().fill(modelColor).frame(width: 4, height: 20)
                        .offset(x: x(model) - 2)
                }
                if let mine = diff.mine {
                    Capsule().fill(mineColor).frame(width: 4, height: 14)
                        .offset(x: x(mine) - 2)
                }
            }
            .frame(height: 20)
        }
        .frame(height: 20)
    }
}
