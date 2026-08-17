import Foundation

/// PRD 赤枠部分の中核。撮影した骨格を基準値と突合し、
/// 「今日直す1点 + 理由 + ドリル + 合格ライン」まで端末内で組み立てる。
///
/// **LLM は呼びません。**処方文はテンプレートへのデータ差し込みです。
/// PRD §10.4 が「励まし文はテンプレート+データ差し込みを基本とし、
/// LLMは低頻度」としているため、これは設計通りの構成です。
enum DiagnosisEngine {

    // MARK: - 代表フレーム

    /// 局面ごとの代表フレーム。指標はそれぞれ自分の局面のフレームで測る。
    struct KeyFrames: Sendable {
        let backswing: Int
        /// バックスイング以降でつま先の速度が最大のフレーム。
        /// 検出できない場合は nil で、インパクトの指標は計測不能になる。
        let impact: Int?
        /// インパクトで観測したつま先の最大速度(m/s)。
        let peakToeSpeed: Double?

        func index(for phase: ReferenceDatabase.Phase) -> Int? {
            switch phase {
            case .backswing: return backswing
            case .impact: return impact
            case .approach: return 0
            case .followThrough: return nil
            }
        }
    }

    // MARK: - 結果の型

    struct Item: Identifiable, Sendable {
        let metric: ReferenceDatabase.Metric
        let measured: Double
        /// 実際に測ったフレーム
        let frameIndex: Int
        let frameTimeMs: Int
        /// 条件から外れた量。満たしていれば 0。
        let deviation: Double
        /// 表示範囲に対する逸脱の割合。指標間で優先順位を比べるために正規化する。
        let severity: Double
        let correction: ReferenceDatabase.Correction?

        var id: String { metric.id }
        var isAcceptable: Bool { deviation == 0 && metric.isPrescribable }

        /// 条件を満たすために必要な境界値。
        var target: Double? { metric.tolerance?.boundary(for: measured) }
    }

    /// 計測の信頼性。PRD「低信頼時は処方を控えめに」の実装。
    struct Quality: Sendable {
        let hasWorldCoordinates: Bool
        let confidence: Float
        let fps: Double
        /// 膝角の1フレームあたり最大変化量。時間解像度の指標。
        let maxKneeDeltaPerFrame: Double
        let warnings: [String]

        var canPrescribe: Bool { hasWorldCoordinates && confidence >= 0.6 }
    }

    struct Diagnosis: Sendable {
        let recordedAt: Date
        let side: JointAngles.Side
        let keyFrames: KeyFrames
        let items: [Item]
        let quality: Quality

        /// PRD「最重要2点」。処方可能なもののうち、逸脱の大きい順に2件。
        var priorities: [Item] {
            items
                .filter { $0.metric.isPrescribable && !$0.isAcceptable && $0.correction != nil }
                .sorted { $0.severity > $1.severity }
                .prefix(2)
                .map { $0 }
        }

        /// 基準値未確定などで参考表示に留まる指標。
        var referenceOnly: [Item] {
            items.filter { !$0.metric.isPrescribable }
        }

        /// 条件を満たしている指標。褒める材料として使う。
        var acceptable: [Item] {
            items.filter(\.isAcceptable)
        }

        /// 局面ごとに測れなかった指標の名前。何が欠けたかを画面に出す。
        let unmeasured: [String]
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

    // MARK: - 入口

    /// - Parameter side: 蹴り足。自動判定は推定が不安定なため、当面は指定する。
    static func diagnose(
        _ sequence: PoseSequence,
        side: JointAngles.Side = .right,
        metrics: [ReferenceDatabase.Metric] = ReferenceDatabase.instepShot
    ) throws -> Diagnosis {

        guard sequence.frames.count >= 5 else { throw DiagnosisError.tooFewFrames }
        guard sequence.worldCoverage > 0.5 else { throw DiagnosisError.noWorldCoordinates }

        guard let backswing = deepestKneeFlexion(sequence, side: side) else {
            throw DiagnosisError.keyFrameNotFound
        }

        let impact = impactFrame(sequence, side: side, after: backswing)

        let keyFrames = KeyFrames(
            backswing: backswing,
            impact: impact?.index,
            peakToeSpeed: impact?.speed
        )

        var items: [Item] = []
        var unmeasured: [String] = []

        for metric in metrics {
            guard let index = keyFrames.index(for: metric.phase),
                  sequence.frames.indices.contains(index),
                  let measurement = measure(metric, in: sequence.frames[index], side: side)
            else {
                unmeasured.append(metric.displayName)
                continue
            }

            items.append(
                makeItem(
                    metric: metric,
                    measured: measurement.degrees,
                    frameIndex: index,
                    frameTimeMs: sequence.frames[index].timestampMs
                )
            )
        }

        let quality = assessQuality(
            sequence,
            side: side,
            keyFrames: keyFrames,
            metrics: metrics
        )

        return Diagnosis(
            recordedAt: sequence.recordedAt,
            side: side,
            keyFrames: keyFrames,
            items: items,
            quality: quality,
            unmeasured: unmeasured
        )
    }

    // MARK: - 代表フレームの検出

    /// 膝角が最小(最も深く曲がった)フレーム。バックスイング最深点の代理指標。
    private static func deepestKneeFlexion(
        _ sequence: PoseSequence,
        side: JointAngles.Side
    ) -> Int? {
        var best: (index: Int, degrees: Double)?

        for (index, frame) in sequence.frames.enumerated() {
            guard let m = JointAngles.kneeFlexion(frame, side: side),
                  m.space == .world,
                  m.confidence >= 0.5
            else { continue }

            if best == nil || m.degrees < best!.degrees {
                best = (index, m.degrees)
            }
        }
        return best?.index
    }

    /// インパクト。バックスイング以降で蹴り足のつま先速度が最大のフレーム。
    ///
    /// 探索をバックスイング以降に限り、かつ蹴り足のみを見ることで、
    /// 軸足の推定が乱れる区間(実測で 44 m/s の異常値を観測)の影響を受けない。
    private static func impactFrame(
        _ sequence: PoseSequence,
        side: JointAngles.Side,
        after backswing: Int
    ) -> (index: Int, speed: Double)? {
        let frames = sequence.frames
        guard backswing + 1 < frames.count else { return nil }

        var best: (index: Int, speed: Double)?

        for i in backswing..<(frames.count - 1) {
            let a = frames[i]
            let b = frames[i + 1]

            let dt = Double(b.timestampMs - a.timestampMs) / 1000
            guard dt > 0 else { continue }
            guard a[side.toe].visibility >= 0.5, b[side.toe].visibility >= 0.5 else { continue }
            guard let p1 = a.worldPoint(side.toe), let p2 = b.worldPoint(side.toe) else { continue }

            let dx = Double(p2.x - p1.x)
            let dy = Double(p2.y - p1.y)
            let dz = Double(p2.z - p1.z)
            let speed = (dx * dx + dy * dy + dz * dz).squareRoot() / dt

            // 人体としてありえない速度は推定の破綻とみなして採用しない。
            // 小学生のインステップで観測された妥当な最大は 10 m/s 前後。
            guard speed < 30 else { continue }

            if best == nil || speed > best!.speed {
                best = (i, speed)
            }
        }
        return best
    }

    // MARK: - 計測

    private static func measure(
        _ metric: ReferenceDatabase.Metric,
        in frame: PoseFrame,
        side: JointAngles.Side
    ) -> JointAngles.Measurement? {
        let measurement: JointAngles.Measurement?

        switch metric.id {
        case "knee_flexion_backswing":
            measurement = JointAngles.kneeFlexion(frame, side: side)
        case "trunk_lean_backswing":
            measurement = JointAngles.trunkLean(frame)
        case "ankle_plantarflexion_impact":
            measurement = JointAngles.anklePlantarFlexion(frame, side: side)
        default:
            measurement = nil
        }

        // 角度定義が一致しない、または画像座標での計測値は基準値と比較できない。
        guard let m = measurement, m.space == .world else { return nil }
        guard metric.angleDefinitionVersion == JointAngles.definitionVersion else { return nil }
        return m
    }

    private static func makeItem(
        metric: ReferenceDatabase.Metric,
        measured: Double,
        frameIndex: Int,
        frameTimeMs: Int
    ) -> Item {
        guard let tolerance = metric.tolerance else {
            return Item(
                metric: metric, measured: measured,
                frameIndex: frameIndex, frameTimeMs: frameTimeMs,
                deviation: 0, severity: 0, correction: nil
            )
        }

        let deviation = tolerance.deviation(of: measured)
        let correction: ReferenceDatabase.Correction? =
            deviation > 0 ? metric.whenAbove : (deviation < 0 ? metric.whenBelow : nil)

        // 指標ごとに角度のスケールが違うため、表示範囲の幅で正規化して比較可能にする。
        let span = metric.displayRange.upperBound - metric.displayRange.lowerBound
        let severity = span > 0 ? abs(deviation) / span : 0

        return Item(
            metric: metric, measured: measured,
            frameIndex: frameIndex, frameTimeMs: frameTimeMs,
            deviation: deviation, severity: severity, correction: correction
        )
    }

    // MARK: - 品質評価

    private static func assessQuality(
        _ sequence: PoseSequence,
        side: JointAngles.Side,
        keyFrames: KeyFrames,
        metrics: [ReferenceDatabase.Metric]
    ) -> Quality {
        var warnings: [String] = []

        let hasWorld = sequence.worldCoverage > 0.9
        if !hasWorld {
            warnings.append("3D座標が一部のフレームにありません。数値の信頼性が下がります。")
        }

        let confidence = sequence.frames[keyFrames.backswing].coreConfidence
        if confidence < 0.6 {
            warnings.append("関節の検出信頼度が低いです。明るい場所で全身が映るように撮り直すと精度が上がります。")
        }

        let fps = sequence.averageFPS
        if fps < 60 {
            warnings.append("フレームレートが\(Int(fps))fpsです。インパクトの瞬間を捉えられていない可能性があります。")
        }

        let delta = maxKneeDelta(sequence, side: side)
        if delta > 20 {
            warnings.append("膝の角度が1フレームで最大\(Int(delta))度動いています。極値を取り逃がしている可能性があります。")
        }

        if keyFrames.impact == nil,
           metrics.contains(where: { $0.phase == .impact }) {
            warnings.append("インパクトのフレームを特定できませんでした。蹴る動作全体が収まるように撮影してください。")
        }

        return Quality(
            hasWorldCoordinates: hasWorld,
            confidence: confidence,
            fps: fps,
            maxKneeDeltaPerFrame: delta,
            warnings: warnings
        )
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
}
