import SwiftUI

/// お手本と自分の骨格を重ねて比較する画面。
///
/// 「見せて真似ろ」でピンとこない相手に、**どこがどう違うか**を
/// 視覚と数値の両方で示すことを目的にしている。
struct ComparisonView: View {

    let result: PoseComparison.Result

    @State private var relativeMs: Double = 0
    @State private var isPlaying = false
    @State private var showModel = true
    @State private var showMine = true

    private let mineColor = Color.green
    private let modelColor = Color.orange

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                overlay
                scrubber
                legend
                diffSection

                if !result.cautions.isEmpty {
                    cautionSection
                }
            }
            .padding(20)
        }
        .navigationTitle("お手本とくらべる")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { relativeMs = 0 }
        .task(id: isPlaying) { await animate() }
    }

    // MARK: - 重ね合わせ

    private var overlay: some View {
        ZStack {
            Canvas { context, size in
                // 脚長を1とした正規化座標を、画面に収まるよう拡大する。
                // 体の縦幅はおよそ脚長の2.2倍なので、その分の余裕を取る。
                let scale = size.height / 2.6
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                if showModel, let pose = result.model.pose(atRelativeMs: Int(relativeMs)) {
                    draw(pose, in: &context, center: center, scale: scale,
                         color: modelColor, lineWidth: 7, opacity: 0.55)
                }
                if showMine, let pose = result.mine.pose(atRelativeMs: Int(relativeMs)) {
                    draw(pose, in: &context, center: center, scale: scale,
                         color: mineColor, lineWidth: 5, opacity: 1.0)
                }
            }
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))

            VStack {
                HStack {
                    Text(String(format: "%+d ms", Int(relativeMs)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(8)
                    Spacer()
                }
                Spacer()
                Text(Int(relativeMs) == 0 ? "ボール通過" : " ")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 8)
            }
        }
        .frame(height: 340)
    }

    private func draw(
        _ pose: PoseComparison.NormalizedPose,
        in context: inout GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        color: Color,
        lineWidth: CGFloat,
        opacity: Double
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

        // 関節点は蹴り足だけ強調する
        let side = result.mine.side
        for joint in [side.hip, side.knee, side.ankle, side.toe] where pose.isVisible(joint) {
            let p = screen(joint)
            let r = lineWidth * 0.8
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(opacity))
            )
        }
    }

    // MARK: - 時間軸

    private var scrubber: some View {
        VStack(spacing: 8) {
            Slider(
                value: $relativeMs,
                in: Double(result.sharedRange.lowerBound)...Double(result.sharedRange.upperBound),
                step: 5
            ) {
                Text("時間")
            } minimumValueLabel: {
                Text("\(result.sharedRange.lowerBound)")
                    .font(.caption2.monospacedDigit())
            } maximumValueLabel: {
                Text("+\(result.sharedRange.upperBound)")
                    .font(.caption2.monospacedDigit())
            }
            .onChange(of: relativeMs) { _, _ in
                if isPlaying { isPlaying = false }
            }

            HStack(spacing: 12) {
                Button(isPlaying ? "一時停止" : "再生") { isPlaying.toggle() }
                    .buttonStyle(.bordered)
                Button("ボール通過に戻す") { relativeMs = 0; isPlaying = false }
                    .buttonStyle(.bordered)
                Spacer()
            }

            Text("ボールに当たる瞬間を 0ms として、2本の時間軸を揃えています。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $showMine) {
                HStack(spacing: 6) {
                    Circle().fill(mineColor).frame(width: 10, height: 10)
                    Text(result.mine.label)
                        .font(.subheadline)
                }
            }
            .toggleStyle(.button)

            Toggle(isOn: $showModel) {
                HStack(spacing: 6) {
                    Circle().fill(modelColor).frame(width: 10, height: 10)
                    Text(result.model.label)
                        .font(.subheadline)
                }
            }
            .toggleStyle(.button)

            Spacer()
        }
    }

    // MARK: - 差分

    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("どこが違うか")
                .font(.headline)

            VStack(spacing: 16) {
                ForEach(result.diffs) { diff in
                    DiffRow(diff: diff, mineColor: mineColor, modelColor: modelColor)
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))

            Text("体格の差を消すため、脚の長さを揃えて重ねています。数値は参考値です。")
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
        let step = 10.0
        while isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            relativeMs += step
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
                    Text("—")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(v.map { String(format: "%.0f%@", $0, diff.metric.unit) } ?? "—")
                .font(.caption.bold().monospacedDigit())
        }
    }

    /// 2つの値を同じ軸に並べる。差が視覚的に分かればよく、精度は求めない。
    private var bar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let range = diff.metric.displayRange
            let span = range.upperBound - range.lowerBound

            let x: (Double) -> CGFloat = { value in
                guard span > 0 else { return 0 }
                let ratio = (value - range.lowerBound) / span
                return CGFloat(min(max(ratio, 0), 1)) * width
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 6)

                if let tolerance = diff.metric.tolerance {
                    let span2 = tolerance.acceptableSpan(in: range)
                    Capsule()
                        .fill(.green.opacity(0.35))
                        .frame(width: max(x(span2.upperBound) - x(span2.lowerBound), 3), height: 6)
                        .offset(x: x(span2.lowerBound))
                }

                if let model = diff.model {
                    Capsule()
                        .fill(modelColor)
                        .frame(width: 4, height: 20)
                        .offset(x: x(model) - 2)
                }
                if let mine = diff.mine {
                    Capsule()
                        .fill(mineColor)
                        .frame(width: 4, height: 14)
                        .offset(x: x(mine) - 2)
                }
            }
            .frame(height: 20)
        }
        .frame(height: 20)
    }
}
