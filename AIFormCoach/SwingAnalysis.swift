import Foundation

/// キック動作を運動連鎖として解析する。
///
/// **背景**
/// キックは股関節・膝関節・足首の連動動作で、ゴルフのスイングと同じく
/// 近位（体幹側）から遠位（つま先側）へ順にピークが訪れることで
/// 先端速度が最大化される。うまく蹴れていない状態は、この順序が崩れているか、
/// 最速の瞬間がボール位置とずれている。
///
/// **測れるもの・測れないもの（Phase 0 実測に基づく）**
/// - 大腿の角速度（股関節の円運動）… 大腿34cm・変動係数3〜6%。測れる
/// - 下腿の角速度 … 下腿43cm・変動係数2〜5%。測れる
/// - 膝関節の角速度 … 膝内角の微分。S/N 55〜254倍。測れる
/// - 足首 … 足長10cm・変動係数20〜28%。**測れない**
/// - 軸足の踏み込み（水平方向の加速）… worldLandmarks は腰中点が原点のため
///   体の並進が除かれており、**原理的に取れない**
///
/// つまり運動連鎖4要素のうち、確度をもって測れるのは2リンク分である。
enum SwingAnalysis {

    // MARK: - 設定

    /// ピークを探す範囲。膝最深を基準に前後この時間だけを見る。
    ///
    /// **フレーム数で指定してはならない。** 120fpsと30fpsで実際の長さが4倍変わる。
    /// 実測で、これを前後40〜50フレーム（120fpsで−333〜+417ms）にしていたため、
    /// キック後の着地動作（+284msに1406°/s）を本来のピーク（−17msに901°/s）より
    /// 大きい値として拾っていた。±150msに絞ったところ、13歳3本の下腿角速度の
    /// 標準偏差が180→70に、連鎖の時間差が SD 5.3ms まで収束した。
    static let peakSearchWindowMs = 150

    /// 角速度を求める中心差分の半幅。隣接フレーム差より雑音が小さい。
    static let velocityHalfWindowMs = 25

    // MARK: - 結果の型

    struct AngularPeak: Sendable {
        let degreesPerSecond: Double
        let index: Int
        /// 膝最深を0としたときの時刻（ミリ秒）。
        let offsetMs: Int
    }

    struct Result: Sendable {
        let side: JointAngles.Side

        // ── 局面 ─────────────────────────────
        /// バックスイング最深（膝内角が最小）。
        let backswingIndex: Int
        let backswingTimeMs: Int
        let backswingKneeAngle: Double

        /// 蹴り足が軸足を追い越す瞬間。インステップキックではボールが
        /// 軸足の横に置かれるため、ミートポイントの代理指標として使える。
        /// 軸足くるぶしは推定が安定しており、ボール検出を必要としない。
        let crossingIndex: Int?
        /// 膝最深からの経過時間。
        let crossingOffsetMs: Int?

        // ── 運動連鎖 ─────────────────────────
        /// 大腿の絶対角速度のピーク（股関節の円運動）。
        let thighPeak: AngularPeak?
        /// 下腿の絶対角速度のピーク。
        let shankPeak: AngularPeak?
        /// 膝関節の相対角速度のピーク（下腿が大腿に対して回る速さ）。
        let kneeExtensionPeak: AngularPeak?

        /// 大腿ピーク → 下腿ピークの時間差。
        /// 正なら近位から遠位への順序（理想）。実測では26〜36ms。
        var chainLagMs: Int? {
            guard let t = thighPeak, let s = shankPeak else { return nil }
            return s.offsetMs - t.offsetMs
        }

        var isProximalToDistal: Bool? {
            guard let lag = chainLagMs else { return nil }
            return lag > 0
        }

        // ── ミートポイントでの状態 ─────────────
        /// 軸足通過時の膝内角。180°が完全伸展。
        let kneeAngleAtCrossing: Double?
        /// 軸足通過時の下腿角速度。
        let shankVelocityAtCrossing: Double?

        /// 通過時の下腿角速度 ÷ ピーク角速度。
        ///
        /// **最速の瞬間をボール位置に合わせられているか**を表す。
        /// 1.0 に近いほどタイミングが合っている。
        /// 実測: 大人 0.94〜0.97 / 13歳 0.69〜0.94。
        var velocityEfficiency: Double? {
            guard let atCrossing = shankVelocityAtCrossing,
                  let peak = shankPeak?.degreesPerSecond,
                  peak > 0
            else { return nil }
            return min(atCrossing / peak, 1.0)
        }

        /// 膝最深から軸足通過までに、膝がどれだけ伸びたか。
        var kneeExtensionUntilCrossing: Double? {
            guard let atCrossing = kneeAngleAtCrossing else { return nil }
            return atCrossing - backswingKneeAngle
        }
    }

    enum AnalysisError: LocalizedError {
        case tooFewFrames
        case noWorldCoordinates
        case noPlausibleBackswing
        case noForwardAxis

        var errorDescription: String? {
            switch self {
            case .tooFewFrames:
                return "フレーム数が足りません。"
            case .noWorldCoordinates:
                return "3D座標がないため解析できません。"
            case .noPlausibleBackswing:
                return "バックスイングを検出できませんでした。膝の推定が破綻している可能性があります。"
            case .noForwardAxis:
                return "体の向きを判定できませんでした。"
            }
        }
    }

    // MARK: - 入口

    static func analyze(
        _ sequence: PoseSequence,
        side: JointAngles.Side = .right
    ) throws -> Result {

        let frames = sequence.frames
        guard frames.count >= 5 else { throw AnalysisError.tooFewFrames }
        guard sequence.worldCoverage > 0.5 else { throw AnalysisError.noWorldCoordinates }
        guard let forward = forwardAxis(of: sequence) else { throw AnalysisError.noForwardAxis }

        let times = frames.map(\.timestampMs)

        // ── 膝内角の時系列（角速度の計算にのみ使う。局面検出には使わない）
        let kneeAngles: [Double?] = frames.map { frame in
            guard let m = JointAngles.kneeInteriorAngle(frame, side: side), m.space == .world else {
                return nil
            }
            return m.degrees
        }

        // ── バックスイング最深（屈曲角が最大のフレーム）
        guard let backswing = JointAngles.deepestFlexionIndex(in: sequence, side: side) else {
            throw AnalysisError.noPlausibleBackswing
        }
        guard let backswingAngle = JointAngles.kneeFlexion(frames[backswing], side: side)?.degrees
        else { throw AnalysisError.noPlausibleBackswing }

        // ── 角速度の3系列
        let thighVelocity = segmentAngularVelocity(frames, times, from: side.hip, to: side.knee)
        let shankVelocity = segmentAngularVelocity(frames, times, from: side.knee, to: side.ankle)
        let kneeVelocity = jointAngularVelocity(kneeAngles, times)

        // ── ピーク探索（ミリ秒で区切る）
        let window = searchWindow(times: times, around: backswing)
        let thighPeak = peak(in: thighVelocity, indices: window, times: times, origin: times[backswing])
        let shankPeak = peak(in: shankVelocity, indices: window, times: times, origin: times[backswing])
        let kneePeak = peak(in: kneeVelocity, indices: window, times: times, origin: times[backswing])

        // ── 軸足通過
        let crossing = supportFootCrossing(
            frames, times, side: side, forward: forward, after: backswing
        )

        var kneeAtCrossing: Double?
        var shankAtCrossing: Double?
        if let crossing {
            kneeAtCrossing = kneeAngles[crossing]
            shankAtCrossing = shankVelocity[crossing]
        }

        return Result(
            side: side,
            backswingIndex: backswing,
            backswingTimeMs: times[backswing],
            backswingKneeAngle: backswingAngle,
            crossingIndex: crossing,
            crossingOffsetMs: crossing.map { times[$0] - times[backswing] },
            thighPeak: thighPeak,
            shankPeak: shankPeak,
            kneeExtensionPeak: kneePeak,
            kneeAngleAtCrossing: kneeAtCrossing,
            shankVelocityAtCrossing: shankAtCrossing
        )
    }

    // MARK: - ピーク探索

    /// 膝最深の前後 peakSearchWindowMs 以内のフレーム。
    private static func searchWindow(times: [Int], around origin: Int) -> [Int] {
        let t0 = times[origin]
        return times.indices.filter { abs(times[$0] - t0) <= peakSearchWindowMs }
    }

    private static func peak(
        in series: [Double?],
        indices: [Int],
        times: [Int],
        origin: Int
    ) -> AngularPeak? {
        let valid = indices.filter { series[$0] != nil }
        guard let best = valid.max(by: { (series[$0] ?? 0) < (series[$1] ?? 0) }),
              let value = series[best], value > 0
        else { return nil }
        return AngularPeak(degreesPerSecond: value, index: best, offsetMs: times[best] - origin)
    }

    // MARK: - 角速度

    /// セグメント（大腿・下腿）が空間内で回転する速さ。腰基準の座標系で計算する。
    /// 中心差分にすることで、隣接フレーム差より雑音を抑える。
    private static func segmentAngularVelocity(
        _ frames: [PoseFrame],
        _ times: [Int],
        from a: PoseJoint,
        to b: PoseJoint
    ) -> [Double?] {
        frames.indices.map { i in
            var lo = i, hi = i
            while lo > 0, times[i] - times[lo - 1] <= velocityHalfWindowMs { lo -= 1 }
            while hi < frames.count - 1, times[hi + 1] - times[i] <= velocityHalfWindowMs { hi += 1 }

            let dt = Double(times[hi] - times[lo]) / 1000
            guard dt > 0,
                  let u1 = direction(frames[lo], from: a, to: b),
                  let u2 = direction(frames[hi], from: a, to: b)
            else { return nil }

            let dot = max(-1, min(1, u1.0 * u2.0 + u1.1 * u2.1 + u1.2 * u2.2))
            return acos(dot) * 180 / .pi / dt
        }
    }

    /// 関節角そのものの時間変化。正なら伸展方向。
    private static func jointAngularVelocity(_ angles: [Double?], _ times: [Int]) -> [Double?] {
        angles.indices.map { i in
            var lo = i, hi = i
            while lo > 0, times[i] - times[lo - 1] <= velocityHalfWindowMs { lo -= 1 }
            while hi < angles.count - 1, times[hi + 1] - times[i] <= velocityHalfWindowMs { hi += 1 }

            let dt = Double(times[hi] - times[lo]) / 1000
            guard dt > 0, let a = angles[lo], let b = angles[hi] else { return nil }
            return (b - a) / dt
        }
    }

    private static func direction(
        _ frame: PoseFrame,
        from a: PoseJoint,
        to b: PoseJoint
    ) -> (Double, Double, Double)? {
        guard let pa = frame.worldPoint(a), let pb = frame.worldPoint(b) else { return nil }
        let dx = Double(pb.x - pa.x), dy = Double(pb.y - pa.y), dz = Double(pb.z - pa.z)
        let length = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard length > 1e-6 else { return nil }
        return (dx / length, dy / length, dz / length)
    }

    // MARK: - 軸足通過（ミートポイントの代理指標）

    /// 蹴り足くるぶしが軸足くるぶしを前方向に追い越す最初のフレーム。
    ///
    /// インステップキックではボールが軸足の横に置かれるため、この瞬間が
    /// ミートポイントに相当する。ボールを画像から検出する必要がない。
    ///
    /// 注意:実際のボールは軸足くるぶしより数センチ前方に置かれるため、
    /// 真のインパクトはこれより僅かに早い可能性がある。実測では通過までの
    /// 時間が25〜33msと揃っており、定義としては安定している。
    private static func supportFootCrossing(
        _ frames: [PoseFrame],
        _ times: [Int],
        side: JointAngles.Side,
        forward: (x: Double, z: Double),
        after backswing: Int
    ) -> Int? {
        let support = side.opposite

        func projection(_ frame: PoseFrame, _ joint: PoseJoint) -> Double? {
            guard let p = frame.worldPoint(joint) else { return nil }
            return Double(p.x) * forward.x + Double(p.z) * forward.z
        }

        // 蹴り足 − 軸足。負から正へ変わる点が追い越しの瞬間。
        var difference: [Double?] = []
        for frame in frames {
            if let k = projection(frame, side.ankle), let s = projection(frame, support.ankle) {
                difference.append(k - s)
            } else {
                difference.append(nil)
            }
        }

        let limit = times[backswing] + peakSearchWindowMs
        for i in backswing..<(frames.count - 1) where times[i] <= limit {
            guard let a = difference[i], let b = difference[i + 1] else { continue }
            if a <= 0, b > 0 { return i }
        }

        // 追い越さなかった場合、窓内で最も前に出た点を返す。
        let window = frames.indices.filter {
            $0 >= backswing && times[$0] <= limit && difference[$0] != nil
        }
        return window.max { (difference[$0] ?? -.infinity) < (difference[$1] ?? -.infinity) }
    }

    // MARK: - 前方向

    /// 肩ラインに直交する水平方向のうち、鼻が来る側を前とする。
    /// クリップ全体の中央値で決め、頭の向きのぶれで符号が反転しないようにする。
    static func forwardAxis(of sequence: PoseSequence) -> (x: Double, z: Double)? {
        var xs: [Double] = [], zs: [Double] = []

        for frame in sequence.frames {
            guard let ls = frame.worldPoint(.leftShoulder),
                  let rs = frame.worldPoint(.rightShoulder),
                  let nose = frame.worldPoint(.nose)
            else { continue }

            let ex = Double(rs.x - ls.x), ez = Double(rs.z - ls.z)
            let length = (ex * ex + ez * ez).squareRoot()
            guard length > 1e-6 else { continue }

            var fx = -ez / length, fz = ex / length
            let sx = Double(ls.x + rs.x) / 2, sz = Double(ls.z + rs.z) / 2
            if (Double(nose.x) - sx) * fx + (Double(nose.z) - sz) * fz < 0 {
                fx = -fx; fz = -fz
            }
            xs.append(fx); zs.append(fz)
        }

        guard !xs.isEmpty else { return nil }
        let fx = median(xs), fz = median(zs)
        let length = (fx * fx + fz * fz).squareRoot()
        guard length > 1e-6 else { return nil }
        return (fx / length, fz / length)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
