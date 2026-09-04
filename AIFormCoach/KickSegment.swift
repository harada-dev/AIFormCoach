import Foundation

/// クリップの中からキック動作の区間を特定し、時間軸の基準点を決める。
///
/// **なぜ必要か**
/// 「膝が最も深く曲がったフレーム」をクリップ全域から探す方式は、
/// 実測5本のうち3本で誤った瞬間を拾っていた。5秒の中には立位・歩行・
/// キック・戻りが含まれ、**歩行中も膝は深く曲がる**ため区別できない。
/// 11歳のクリップでは蹴った2.2秒後の歩行を「膝最深」として拾っており、
/// 値が93°とそれらしいため誤りに気づけなかった。
///
/// **検出の原理**
/// キックの特徴は「蹴り足が大きく後ろに引かれてから前に振り抜かれる」こと。
/// 蹴り足くるぶしと軸足くるぶしの前後差 d(t) を取ると、キックでは
/// 大きく振れる(実測 振幅 1.2〜1.6)が、歩行では小さい。
/// 800msの移動窓で振幅が最大の区間をキックとみなす。
///
/// **基準点**
/// ボール通過(蹴り足が軸足を追い越す瞬間)を第一候補とする。
/// 「ボールに当たる瞬間」は全員共通の意味を持ち、実測で膝最深から
/// +17〜+33msに安定していた。検出できない場合は膝最深に落とす。
enum KickSegment {

    /// キック区間を探す移動窓の幅。
    static let searchWindowMs = 800

    /// 区間として認めるための最小振幅(脚長で正規化した単位ではなくメートル)。
    /// 実測のキックは 1.18〜1.64 だった。歩行はこれを大きく下回る。
    static let minimumAmplitude = 0.5

    struct Result: Sendable {
        /// 蹴り足が最も後方にあるフレーム。
        let backmostIndex: Int
        /// 蹴り足が最も前方に振り抜かれたフレーム。
        let followThroughIndex: Int
        /// 区間内で膝屈曲が最大のフレーム。
        let deepestFlexionIndex: Int
        /// 蹴り足が軸足を追い越すフレーム。検出できないことがある。
        let crossingIndex: Int?
        /// d(t) の振幅。区間の確度の目安。
        let amplitude: Double

        /// 時間軸を揃える基準点。ボール通過を優先し、無ければ膝最深。
        var anchorIndex: Int { crossingIndex ?? deepestFlexionIndex }

        var anchorDescription: String {
            crossingIndex != nil ? "ボール通過" : "バックスイング最深"
        }
    }

    // MARK: - 検出

    static func detect(in sequence: PoseSequence, side: JointAngles.Side) -> Result? {
        let frames = sequence.frames
        guard frames.count >= 10, let forward = JointAngles.forwardAxis(of: sequence) else {
            return nil
        }
        let times = frames.map(\.timestampMs)

        // 蹴り足 − 軸足 の前後差
        let support = side.opposite
        var separation = [Double?](repeating: nil, count: frames.count)
        for i in frames.indices {
            guard let kick = frames[i].worldPoint(side.ankle),
                  let stance = frames[i].worldPoint(support.ankle)
            else { continue }
            let a = Double(kick.x) * forward.x + Double(kick.z) * forward.z
            let b = Double(stance.x) * forward.x + Double(stance.z) * forward.z
            separation[i] = a - b
        }

        // 屈曲角
        let flexion: [Double?] = frames.map { frame in
            guard let m = JointAngles.kneeFlexion(frame, side: side), m.space == .world else {
                return nil
            }
            return m.degrees
        }

        // 800ms の移動窓で振幅が最大の区間を探す
        var best: (start: Int, amplitude: Double, window: [Int])?
        for i in frames.indices {
            let window = frames.indices.filter {
                $0 >= i && times[$0] - times[i] <= searchWindowMs && separation[$0] != nil
            }
            guard window.count >= 10 else { continue }

            let values = window.compactMap { separation[$0] }
            guard let high = values.max(), let low = values.min() else { continue }
            let amplitude = high - low

            if best == nil || amplitude > best!.amplitude {
                best = (i, amplitude, window)
            }
        }

        guard let best, best.amplitude >= minimumAmplitude else { return nil }

        let window = best.window
        guard let backmost = window.min(by: { (separation[$0] ?? 0) < (separation[$1] ?? 0) }),
              let followThrough = window.max(by: { (separation[$0] ?? 0) < (separation[$1] ?? 0) })
        else { return nil }

        // 後方 → 前方 の範囲に絞って膝最深を探す
        let lower = min(backmost, followThrough)
        let upper = max(backmost, followThrough)
        let segment = Array(lower...upper).filter { flexion[$0] != nil }
        let deepest = segment.max(by: { (flexion[$0] ?? 0) < (flexion[$1] ?? 0) }) ?? best.start

        // 区間内で d が負から正へ変わる点
        var crossing: Int?
        for i in lower..<upper {
            guard let a = separation[i], let b = separation[i + 1] else { continue }
            if a <= 0, b > 0 { crossing = i; break }
        }

        return Result(
            backmostIndex: backmost,
            followThroughIndex: followThrough,
            deepestFlexionIndex: deepest,
            crossingIndex: crossing,
            amplitude: best.amplitude
        )
    }
}
