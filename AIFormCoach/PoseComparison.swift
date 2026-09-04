import Foundation
import CoreGraphics

/// 2つの骨格を重ねて比較するためのモデル。
///
/// **なぜ画像座標を使わないか**
/// カメラの位置と被写体距離が違うため、2D画像座標をそのまま重ねても
/// 比較になりません。3D座標(腰中点原点)を骨長で正規化してから、
/// あらためて2Dに投影します。両方が真横撮影であれば、この投影が
/// 比較可能な同一視点になります。
///
/// **揃えるもの**
/// - 体格:大腿+下腿の長さを1として正規化。体格差を消してフォームだけを比べる
/// - 時間軸:`KickSegment`でクリップ内のキック区間を特定し、ボール通過
///   (検出できなければ区間内の膝最深)を0msとして前後を揃える。
///   クリップ全域から膝最深を探すと、歩行中の深い膝屈曲を誤検出することがある
/// - 向き:前方向の符号が違う場合はx座標を反転。左向きと右向きを揃える
enum PoseComparison {

    // MARK: - 正規化された姿勢

    /// 骨長を1として正規化した2D投影。腰の中点が原点、y は下向き正。
    struct NormalizedPose: Sendable {
        /// 33要素。単位は「大腿+下腿の長さ = 1」。
        var points: [CGPoint]
        var visibility: [Float]

        subscript(joint: PoseJoint) -> CGPoint { points[joint.rawValue] }
        func isVisible(_ joint: PoseJoint) -> Bool { visibility[joint.rawValue] >= 0.4 }
    }

    // MARK: - 1本のクリップ

    struct Track: Sendable {
        let label: String
        let side: JointAngles.Side
        /// 時間軸の原点。ボール通過(なければキック区間内の膝最深)のフレーム番号。
        let originIndex: Int
        /// 正規化に使った脚の長さ(m)。実寸の参考にもなる。
        let legLength: Double
        /// x座標を反転するか(向きを揃えるため)。
        let mirrored: Bool
        /// 診断結果。指標の差分に使う。取得できなければ nil。
        let diagnosis: DiagnosisEngine.Diagnosis?
        /// 基準点が何だったか。
        let anchorDescription: String

        fileprivate let frames: [PoseFrame]
        fileprivate let times: [Int]

        /// 原点(originIndex)を0msとしたときの利用可能な時間範囲。
        var relativeRange: ClosedRange<Int> {
            guard let first = times.first, let last = times.last else { return 0...0 }
            let origin = times[originIndex]
            return (first - origin)...(last - origin)
        }

        /// 指定した相対時刻に最も近いフレームの正規化姿勢。
        func pose(atRelativeMs ms: Int) -> NormalizedPose? {
            guard !frames.isEmpty else { return nil }
            let target = times[originIndex] + ms

            var best = 0
            var bestDistance = Int.max
            for i in times.indices {
                let d = abs(times[i] - target)
                if d < bestDistance { bestDistance = d; best = i }
            }
            return normalize(frames[best], legLength: legLength, mirrored: mirrored)
        }

        /// 膝屈曲角の時系列(相対時刻付き)。グラフ表示に使える。
        func kneeFlexionSeries() -> [(relativeMs: Int, degrees: Double)] {
            let origin = times[originIndex]
            return frames.indices.compactMap { i in
                guard let m = JointAngles.kneeFlexion(frames[i], side: side),
                      m.space == .world else { return nil }
                return (times[i] - origin, m.degrees)
            }
        }
    }

    // MARK: - 比較

    struct MetricDiff: Identifiable, Sendable {
        let metric: ReferenceDatabase.Metric
        let mine: Double?
        let model: Double?
        /// 自分 − お手本。正なら自分の方が大きい。
        let delta: Double?
        /// 差を埋めるための助言。基準値がある指標のみ。
        let hint: String?

        var id: String { metric.id }
    }

    struct Result: Sendable {
        let mine: Track
        let model: Track
        let diffs: [MetricDiff]
        /// 両方に共通する相対時刻の範囲。
        let sharedRange: ClosedRange<Int>
        /// 撮影条件が揃っていないなどの注意。
        let cautions: [String]
        /// 時間軸を揃えた基準点の名前(「ボール通過」または「バックスイング最深」)。
        let anchorDescription: String
    }

    enum ComparisonError: LocalizedError {
        case cannotAlign(String)

        var errorDescription: String? {
            switch self {
            case .cannotAlign(let label):
                return "\(label)のバックスイングを検出できませんでした。比較できません。"
            }
        }
    }

    // MARK: - 組み立て

    static func compare(
        mine: PoseSequence,
        mineLabel: String = "自分",
        mineSide: JointAngles.Side = .right,
        model: PoseSequence,
        modelLabel: String = "お手本",
        modelSide: JointAngles.Side = .right
    ) throws -> Result {

        let mineTrack = try makeTrack(mine, label: mineLabel, side: mineSide)
        var modelTrack = try makeTrack(model, label: modelLabel, side: modelSide)

        // 向きを揃える。前方向のx成分の符号が違えば、お手本側を反転する。
        if let a = JointAngles.forwardAxis(of: mine),
           let b = JointAngles.forwardAxis(of: model),
           a.x * b.x < 0 {
            modelTrack = modelTrack.mirroring()
        }

        // 体格を揃える。お手本を自分の脚長にスケールし直す。
        // 正規化は既に脚長=1で行っているため、描画時は同一スケールになる。

        // キックの前後だけに絞る。クリップ全体を動かせても使いづらい。
        let lower = max(mineTrack.relativeRange.lowerBound, modelTrack.relativeRange.lowerBound, -600)
        let upper = min(mineTrack.relativeRange.upperBound, modelTrack.relativeRange.upperBound, 400)
        let shared = lower <= upper ? lower...upper : 0...0

        var cautions: [String] = []
        if let d = mineTrack.diagnosis, !d.quality.isSideView {
            cautions.append("自分の記録が真横から撮影されていません。重ね合わせのずれが大きくなります。")
        }
        if let d = modelTrack.diagnosis, !d.quality.isSideView {
            cautions.append("お手本が真横から撮影されていません。重ね合わせのずれが大きくなります。")
        }
        let ratio = mineTrack.legLength / modelTrack.legLength
        if ratio < 0.8 || ratio > 1.25 {
            cautions.append(String(
                format: "体格差が大きいため、脚の長さを揃えて比較しています(自分 %.2fm / お手本 %.2fm)。",
                mineTrack.legLength, modelTrack.legLength
            ))
        }

        return Result(
            mine: mineTrack,
            model: modelTrack,
            diffs: makeDiffs(mine: mineTrack, model: modelTrack),
            sharedRange: shared,
            cautions: cautions,
            anchorDescription: mineTrack.anchorDescription
        )
    }

    private static func makeTrack(
        _ sequence: PoseSequence,
        label: String,
        side: JointAngles.Side
    ) throws -> Track {
        // 破綻フレームを補間してから比較する。
        let repaired = PoseIntegrity.repair(sequence).repaired

        // キック区間を特定し、その中から基準点を決める。
        // 全域から膝最深を探す方式は、実測5本のうち3本で歩行など
        // 別の動作を拾っていた(最大2.2秒のずれ)。
        let origin: Int
        let anchorName: String
        if let segment = KickSegment.detect(in: repaired, side: side) {
            origin = segment.anchorIndex
            anchorName = segment.anchorDescription
        } else if let fallback = JointAngles.deepestFlexionIndex(in: repaired, side: side) {
            origin = fallback
            anchorName = "バックスイング最深"
        } else {
            throw ComparisonError.cannotAlign(label)
        }
        guard let legLength = legLength(of: repaired, side: side) else {
            throw ComparisonError.cannotAlign(label)
        }

        return Track(
            label: label,
            side: side,
            originIndex: origin,
            legLength: legLength,
            mirrored: false,
            diagnosis: try? DiagnosisEngine.diagnose(repaired, side: side),
            anchorDescription: anchorName,
            frames: repaired.frames,
            times: repaired.frames.map(\.timestampMs)
        )
    }

    private static func makeDiffs(mine: Track, model: Track) -> [MetricDiff] {
        let mineItems = mine.diagnosis?.items ?? []
        let modelItems = model.diagnosis?.items ?? []

        return ReferenceDatabase.instepShot.map { metric in
            let a = mineItems.first { $0.metric.id == metric.id }?.measured
            let b = modelItems.first { $0.metric.id == metric.id }?.measured
            let delta = (a != nil && b != nil) ? a! - b! : nil

            var hint: String?
            if let delta, abs(delta) >= 5, metric.isPrescribable {
                // 差の方向に応じて、基準値DBの助言を流用する。
                let correction = delta < 0 ? metric.whenBelow : metric.whenAbove
                if let correction {
                    hint = correction.reason
                }
            }

            return MetricDiff(metric: metric, mine: a, model: b, delta: delta, hint: hint)
        }
    }

    // MARK: - 正規化

    /// 大腿 + 下腿の長さ(m)。クリップ全体の中央値を使う。
    static func legLength(of sequence: PoseSequence, side: JointAngles.Side) -> Double? {
        var values: [Double] = []
        for frame in sequence.frames {
            guard let hip = frame.worldPoint(side.hip),
                  let knee = frame.worldPoint(side.knee),
                  let ankle = frame.worldPoint(side.ankle)
            else { continue }
            values.append(distance(hip, knee) + distance(knee, ankle))
        }
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return median > 0.1 ? median : nil
    }

    /// 3D座標を脚長で正規化し、x-y平面に投影する。
    /// 腰の中点を原点にするため、worldLandmarks の原点をそのまま使う。
    static func normalize(
        _ frame: PoseFrame,
        legLength: Double,
        mirrored: Bool
    ) -> NormalizedPose? {
        guard frame.hasWorld, legLength > 0.1 else { return nil }

        let sign: CGFloat = mirrored ? -1 : 1
        var points = [CGPoint]()
        points.reserveCapacity(frame.world.count)

        for p in frame.world {
            points.append(CGPoint(
                x: sign * CGFloat(Double(p.x) / legLength),
                y: CGFloat(Double(p.y) / legLength)
            ))
        }

        return NormalizedPose(points: points, visibility: frame.keypoints.map(\.visibility))
    }

    private static func distance(_ a: WorldPoint, _ b: WorldPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y), dz = Double(a.z - b.z)
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

private extension PoseComparison.Track {
    func mirroring() -> Self {
        PoseComparison.Track(
            label: label,
            side: side,
            originIndex: originIndex,
            legLength: legLength,
            mirrored: !mirrored,
            diagnosis: diagnosis,
            anchorDescription: anchorDescription,
            frames: frames,
            times: times
        )
    }
}
