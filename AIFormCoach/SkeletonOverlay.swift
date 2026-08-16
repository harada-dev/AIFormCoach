import SwiftUI

/// 骨格の描画。カメラ映像への重ね描きと、読み込んだ骨格の単独再生の両方に使う。
struct SkeletonOverlay: View {
    let frame: PoseFrame?
    /// 単独再生（棒人間のみ）のときは true。線を太くして見やすくする。
    var standalone: Bool = false

    private var lineWidth: CGFloat { standalone ? 6 : 3 }
    private var jointRadius: CGFloat { standalone ? 5 : 3.5 }

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }

            // 骨
            for (a, b) in PoseJoint.bones {
                let ka = frame[a], kb = frame[b]
                guard ka.visibility > 0.4, kb.visibility > 0.4 else { continue }

                var path = Path()
                path.move(to: scale(ka.point, to: size))
                path.addLine(to: scale(kb.point, to: size))

                context.stroke(
                    path,
                    with: .color(color(for: min(ka.visibility, kb.visibility))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }

            // 関節点。顔の細部は省く。
            for joint in PoseJoint.allCases where joint.rawValue >= PoseJoint.leftShoulder.rawValue {
                let kp = frame[joint]
                guard kp.visibility > 0.4 else { continue }
                let p = scale(kp.point, to: size)
                let rect = CGRect(
                    x: p.x - jointRadius, y: p.y - jointRadius,
                    width: jointRadius * 2, height: jointRadius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }

    /// 正規化座標をビュー座標へ。
    /// 注意：カメラプレビューが resizeAspectFill の場合、実際の映像は
    /// 上下または左右がクロップされています。厳密に合わせるには
    /// AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:) を使ってください。
    private func scale(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    /// 信頼度を色で伝える。低信頼を隠さずに見せることが誤診断の防止になる。
    private func color(for visibility: Float) -> Color {
        visibility > 0.7 ? .green : .orange
    }
}

/// 読み込んだ骨格シーケンスを再生する。Phase 0 の「友だちの骨格を見る」体験。
struct SkeletonPlayer: View {
    let sequence: PoseSequence

    @State private var index = 0
    @State private var isPlaying = true

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Color.black
                SkeletonOverlay(frame: currentFrame, standalone: true)
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if !sequence.frames.isEmpty {
                Slider(
                    value: Binding(
                        get: { Double(index) },
                        set: { index = Int($0); isPlaying = false }
                    ),
                    in: 0...Double(max(sequence.frames.count - 1, 1))
                )

                HStack {
                    Button(isPlaying ? "一時停止" : "再生") { isPlaying.toggle() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text("\(index + 1) / \(sequence.frames.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            measurements
        }
        .padding()
        .task(id: isPlaying) { await animate() }
    }

    private var currentFrame: PoseFrame? {
        sequence.frames.indices.contains(index) ? sequence.frames[index] : nil
    }

    @ViewBuilder
    private var measurements: some View {
        if let frame = currentFrame {
            VStack(alignment: .leading, spacing: 6) {
                row("右膝の曲がり", JointAngles.kneeFlexion(frame, side: .right))
                row("体幹の前傾", JointAngles.trunkLean(frame))
                row("右足首の伸び", JointAngles.anklePlantarFlexion(frame, side: .right))
            }
            .font(.callout.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ measurement: JointAngles.Measurement?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let measurement {
                Text(String(format: "%.0f°", measurement.degrees))
            } else {
                Text("計測不能").foregroundStyle(.secondary)
            }
        }
    }

    private func animate() async {
        guard isPlaying, sequence.frames.count > 1 else { return }
        // 収録時のフレーム間隔で再生する。
        let interval = max(1.0 / max(sequence.averageFPS, 1), 1.0 / 60.0)
        while isPlaying && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            index = (index + 1) % sequence.frames.count
        }
    }
}
