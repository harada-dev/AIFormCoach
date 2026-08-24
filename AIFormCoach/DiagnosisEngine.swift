import Foundation

/// PRD 赤枠部分の中核。撮影した骨格を基準値と突合し、
/// 「今日直す1点 + 理由 + ドリル + 合格ライン」まで端末内で組み立てる。
///
/// **LLM は呼びません。**処方文はテンプレートへのデータ差し込みです。
///
/// 設計上の要点(すべて Phase 0 の実測に基づく):
/// - 局面の特定には膝角を使う。長い骨(下腿43cm・大腿34cm)から計算するため
///   推定が安定しており、1フレーム変化の中央値は0.2°だった。
/// - つま先の速度は使わない。座標の差分なので推定誤差が増幅され、
///   9ms間隔で 0.79 → 3.10 → 1.72 m/s と振動した。
/// - 足部を使う指標は区間の中央値で測る。1フレームでは同一動作で
///   13〜15°ずれたが、中央値では1〜2°に収まった。
enum DiagnosisEngine {

    // MARK: - 結果の型

    struct Item: Identifiable, Sendable {
        let metric: ReferenceDatabase.Metric
        let measured: Double
        /// 中央値を取ったフレーム数。単一フレーム測定なら 1。
        let sampleCount: Int
        /// 区間内のばらつき(標準偏差)。台地が安定しているかの目安。
        let spread: Double
        let windowStartMs: Int
        let windowEndMs: Int
        let deviation: Double
        let severity: Double
        let correction: ReferenceDatabase.Correction?
        /// 撮影条件が満たされないなど、判定を保留した理由。
        let suppression: String?

        var id: String { metric.id }
        var isSuppressed: Bool { suppression != nil }
        var isAcceptable: Bool { deviation == 0 && metric.isPrescribable && !isSuppressed }
        var target: Double? { metric.tolerance?.boundary(for: measured) }
    }

    /// 計測の信頼性。PRD「低信頼時は処方を控えめに」の実装。
    struct Quality: Sendable {
        let hasWorldCoordinates: Bool
        let confidence: Float
        let fps: Double
        /// 膝角の1フレームあたり最大変化量。時間解像度の指標。
        let maxKneeDeltaPerFrame: Double
        /// 足長÷下腿長の中央値。スケールに依存しない撮影角度の指標。
        /// 実測で真横 0.25〜0.26、正面 0.19。
        let footShankRatio: Double
        /// 真横から撮れているか。足部を使う指標の可否を決める。
        let isSideView: Bool
        let warnings: [String]

        var canPrescribe: Bool { hasWorldCoordinates && confidence >= 0.6 }
    }

    struct Diagnosis: Sendable {
        let recordedAt: Date
        let side: JointAngles.Side
        let backswingIndex: Int
        let backswingTimeMs: Int
        let backswingKneeAngle: Double
        let items: [Item]
        let quality: Quality
        let unmeasured: [String]

        /// PRD「最重要2点」。処方可能で、条件を外していて、保留されていないもの。
        var priorities: [Item] {
            items
                .filter { $0.metric.isPrescribable && !$0.isAcceptable
                    && !$0.isSuppressed && $0.correction != nil }
                .sorted { $0.severity > $1.severity }
                .prefix(2)
                .map { $0 }
        }

        var acceptable: [Item] { items.filter(\.isAcceptable) }
        var suppressed: [Item] { items.filter(\.isSuppressed) }
        var referenceOnly: [Item] { items.filter { !$0.metric.isPrescribable && !$0.isSuppressed } }

        /// 実際に合否の判定にかけた指標。
        ///
        /// `priorities` が空でも「全部できていた」とは限りません。基準値が未確定
        /// (`tolerance == nil`)の指標や撮影条件で保留した指標は最初から判定に
        /// かかっていないため、これが空のときは「合格した」ではなく
        /// 「そもそも判定していない」が正しい説明になります。
        var judged: [Item] { items.filter { $0.metric.isPrescribable && !$0.isSuppressed } }
    }

    enum DiagnosisError: LocalizedError {
        case tooFewFrames
        case noWorldCoordinates
        case keyFrameNotFound

        var errorDescription: String? {
            switch self {
            case .tooFewFrames:
                return "フレーム数が足りません。もう一度撮影してください。"
            case .noWorldCoordinates:
                return "3D座標がないため診断できません。角度定義v2で撮影したデータが必要です。"
            case .keyFrameNotFound:
                return "蹴り足の動きを検出できませんでした。全身が映るように撮り直してください。"
            }
        }
    }

    /// 足長÷下腿長がこの値を下回ると、カメラに対して奥行き方向を向いていると判断する。
    /// 実測: 真横 0.25〜0.26 / 正面 0.19。
    private static let sideViewRatioThreshold = 0.22

    // MARK: - 入口

    static func diagnose(
        _ sequence: PoseSequence,
        side: JointAngles.Side = .right,
        metrics: [ReferenceDatabase.Metric] = ReferenceDatabase.instepShot
    ) throws -> Diagnosis {

        guard sequence.frames.count >= 5 else { throw DiagnosisError.tooFewFrames }
        guard sequence.worldCoverage > 0.5 else { throw DiagnosisError.noWorldCoordinates }

        guard let backswing = JointAngles.deepestFlexionIndex(in: sequence, side: side) else {
            throw DiagnosisError.keyFrameNotFound
        }

        let quality = assessQuality(sequence, side: side, backswing: backswing)
        let backswingFrame = sequence.frames[backswing]

        var items: [Item] = []
        var unmeasured: [String] = []

        for metric in metrics {
            guard let sample = sample(metric, in: sequence, from: backswing, side: side) else {
                unmeasured.append(metric.displayName)
                continue
            }

            // 撮影角度が満たされない指標は判定を保留する。
            // 実測では正面撮影で足長が3割短く推定され、軽い素振りでも
            // 本気のキックに近い値(105°)が出て誤判定になった。
            let suppression: String? =
                (metric.requiresSideView && !quality.isSideView)
                ? "蹴る方向に対して真横から撮影されていないため、この指標は判定できません。"
                : nil

            items.append(makeItem(metric: metric, sample: sample, suppression: suppression))
        }

        return Diagnosis(
            recordedAt: sequence.recordedAt,
            side: side,
            backswingIndex: backswing,
            backswingTimeMs: backswingFrame.timestampMs,
            backswingKneeAngle: JointAngles.kneeFlexion(backswingFrame, side: side)?.degrees ?? 0,
            items: items,
            quality: quality,
            unmeasured: unmeasured
        )
    }

    // MARK: - 測定

    private struct Sample {
        let value: Double
        let count: Int
        let spread: Double
        let startMs: Int
        let endMs: Int
    }

    private static func sample(
        _ metric: ReferenceDatabase.Metric,
        in sequence: PoseSequence,
        from backswing: Int,
        side: JointAngles.Side
    ) -> Sample? {
        guard metric.angleDefinitionVersion == JointAngles.definitionVersion else { return nil }

        switch metric.sampling {

        case .backswingFrame:
            let frame = sequence.frames[backswing]
            guard let m = measurement(of: metric, in: frame, side: side) else { return nil }
            return Sample(
                value: m, count: 1, spread: 0,
                startMs: frame.timestampMs, endMs: frame.timestampMs
            )

        case .forwardSwingMedian(let windowMs):
            let origin = sequence.frames[backswing].timestampMs
            var values: [Double] = []
            var lastMs = origin

            for index in backswing..<sequence.frames.count {
                let frame = sequence.frames[index]
                guard frame.timestampMs - origin <= windowMs else { break }
                guard let m = measurement(of: metric, in: frame, side: side) else { continue }
                values.append(m)
                lastMs = frame.timestampMs
            }

            // 区間が短すぎると中央値の意味が薄い。実測では104fpsで17枚取れた。
            guard values.count >= 5 else { return nil }

            return Sample(
                value: median(values),
                count: values.count,
                spread: standardDeviation(values),
                startMs: origin,
                endMs: lastMs
            )
        }
    }

    private static func measurement(
        of metric: ReferenceDatabase.Metric,
        in frame: PoseFrame,
        side: JointAngles.Side
    ) -> Double? {
        let result: JointAngles.Measurement?

        switch metric.id {
        case "knee_flexion_backswing":
            result = JointAngles.kneeFlexion(frame, side: side)
        case "trunk_lean_backswing":
            result = JointAngles.trunkLean(frame)
        case "ankle_plantarflexion_forward_swing":
            result = JointAngles.anklePlantarFlexion(frame, side: side)
        default:
            result = nil
        }

        // 画像座標での計測値は撮影角度に依存するため基準値と比較できない。
        guard let m = result, m.space == .world, m.confidence >= 0.5 else { return nil }
        // 規約が一致しない指標は基準値と比較してはならない。
        // 屈曲角の基準値に内角の実測を突合すると、約20°ずれた診断になる。
        guard m.convention == metric.convention else { return nil }
        return m.degrees
    }

    /// この値以下の逸脱は処方しない。
    /// 測定の再現性（SD 3.1〜7.6°）の範囲内では、指摘しても意味がないため。
    /// PRD G6「同一条件での再現ばらつき ±5°以内」に対応する。
    private static let minimumMeaningfulDeviation = 5.0

    private static func makeItem(
        metric: ReferenceDatabase.Metric,
        sample: Sample,
        suppression: String?
    ) -> Item {
        guard let tolerance = metric.tolerance else {
            return Item(
                metric: metric, measured: sample.value,
                sampleCount: sample.count, spread: sample.spread,
                windowStartMs: sample.startMs, windowEndMs: sample.endMs,
                deviation: 0, severity: 0, correction: nil, suppression: suppression
            )
        }

        let rawDeviation = tolerance.deviation(of: sample.value)
        // 誤差の範囲内なら「範囲内」として扱う
        let deviation = abs(rawDeviation) < minimumMeaningfulDeviation ? 0 : rawDeviation
        let correction: ReferenceDatabase.Correction? =
            deviation > 0 ? metric.whenAbove : (deviation < 0 ? metric.whenBelow : nil)

        // 指標ごとに角度のスケールが違うため、表示範囲の幅で正規化して比較可能にする。
        let span = metric.displayRange.upperBound - metric.displayRange.lowerBound
        let severity = span > 0 ? abs(deviation) / span : 0

        return Item(
            metric: metric, measured: sample.value,
            sampleCount: sample.count, spread: sample.spread,
            windowStartMs: sample.startMs, windowEndMs: sample.endMs,
            deviation: deviation, severity: severity,
            correction: correction, suppression: suppression
        )
    }

    // MARK: - 品質評価

    private static func assessQuality(
        _ sequence: PoseSequence,
        side: JointAngles.Side,
        backswing: Int
    ) -> Quality {
        var warnings: [String] = []

        let hasWorld = sequence.worldCoverage > 0.9
        if !hasWorld {
            warnings.append("3D座標が一部のフレームにありません。数値の信頼性が下がります。")
        }

        let confidence = sequence.frames[backswing].coreConfidence
        if confidence < 0.6 {
            warnings.append("関節の検出信頼度が低いです。明るい場所で全身が映るように撮り直すと精度が上がります。")
        }

        let fps = sequence.averageFPS
        if fps < 60 {
            warnings.append("フレームレートが\(Int(fps))fpsです。インパクト前後の角度を取り逃がしている可能性があります。")
        }

        let delta = maxKneeDelta(sequence, side: side)
        if delta > 20 {
            warnings.append("膝の角度が1フレームで最大\(Int(delta))度動いています。極値を取り逃がしている可能性があります。")
        }

        let ratio = footShankRatio(sequence, side: side)
        let isSideView = ratio >= sideViewRatioThreshold
        if !isSideView {
            warnings.append("足の長さが短く推定されています(比 \(String(format: "%.2f", ratio)))。蹴る方向に対して真横から撮ると、足首の指標が測れるようになります。")
        }

        return Quality(
            hasWorldCoordinates: hasWorld,
            confidence: confidence,
            fps: fps,
            maxKneeDeltaPerFrame: delta,
            footShankRatio: ratio,
            isSideView: isSideView,
            warnings: warnings
        )
    }

    /// 足長÷下腿長の中央値。解剖学的にはほぼ一定であるべき指標なので、
    /// 小さく出れば足が奥行き方向を向いている(=真横から撮れていない)。
    private static func footShankRatio(
        _ sequence: PoseSequence,
        side: JointAngles.Side
    ) -> Double {
        var ratios: [Double] = []

        for frame in sequence.frames {
            guard let heel = frame.worldPoint(side.heel),
                  let toe = frame.worldPoint(side.toe),
                  let knee = frame.worldPoint(side.knee),
                  let ankle = frame.worldPoint(side.ankle)
            else { continue }

            let foot = distance(heel, toe)
            let shank = distance(knee, ankle)
            guard shank > 0.05 else { continue }
            ratios.append(foot / shank)
        }
        return ratios.isEmpty ? 0 : median(ratios)
    }

    private static func maxKneeDelta(
        _ sequence: PoseSequence,
        side: JointAngles.Side
    ) -> Double {
        var previous: Double?
        var maximum = 0.0
        for frame in sequence.frames {
            guard let m = JointAngles.kneeFlexion(frame, side: side), m.space == .world else {
                previous = nil
                continue
            }
            if let p = previous { maximum = max(maximum, abs(m.degrees - p)) }
            previous = m.degrees
        }
        return maximum
    }

    // MARK: - 補助

    private static func distance(_ a: WorldPoint, _ b: WorldPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y), dz = Double(a.z - b.z)
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }
}
