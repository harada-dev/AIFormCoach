import Foundation
import CoreGraphics

/// PRD §2 ③「自分の数値」に相当する計測部。
///
/// すべて端末内のルールベース計算です。LLM は一切呼びません。
///
/// **3D座標があるときは必ず 3D で計算します。** 実測で、画像座標で測った
/// 足関節角は撮影角度によって系統的にずれることが確認されました
/// （足長/下腿長 比が 0.21〜1.64 に振れた）。原因は遠近による短縮で、
/// キーポイント自体の誤りではありません。3D座標はこの影響を受けません。
enum JointAngles {

    /// 角度定義のバージョン。
    /// v2 → v3 で膝を内角から屈曲角へ変更したため、**v2 で測った膝の値と互換性がありません。**
    static let definitionVersion = 3

    // MARK: - 角度の規約

    /// 角度をどの規約で表しているか。
    ///
    /// **この型があるのは、規約の取り違えを二度と起こさないためです。**
    /// 実装当初、PRD の「膝屈曲 90〜110°」（屈曲角）を内角として扱っていたため、
    /// 基準値が実測と約20°ずれていました。規約を揃えたところ、
    /// PRD の値・文献値（Cordeiro 2015 / Greig 2018）・実測がすべて 90〜113° で一致しました。
    enum Convention: String, Sendable {
        /// 屈曲角。0° = 完全伸展、値が大きいほど深く曲がっている。
        /// 文献と PRD の基準値がこの規約。
        case flexion = "屈曲角"

        /// 内角。180° = 完全伸展、値が小さいほど深く曲がっている。
        /// キーポイントから直接計算される生の角度。
        case interior = "内角"

        /// 鉛直からのずれ。体幹前傾など、関節角ではない量。
        case fromVertical = "鉛直からのずれ"

        var explanation: String {
            switch self {
            case .flexion: return "0°が完全に伸びた状態。値が大きいほど深く曲がっている"
            case .interior: return "180°が完全に伸びた状態。値が小さいほど深く曲がっている"
            case .fromVertical: return "0°が直立。前が正、後ろが負"
            }
        }
    }

    /// 計測がどの座標系で行われたか。
    enum Space: String, Sendable {
        /// 3D メートル座標。遠近短縮の影響を受けない。
        case world
        /// 画像の正規化座標。撮影角度に依存するため参考値。
        case image
    }

    /// 蹴り足・軸足の左右。
    enum Side: Sendable, Hashable {
        case left, right

        var hip: PoseJoint { self == .left ? .leftHip : .rightHip }
        var knee: PoseJoint { self == .left ? .leftKnee : .rightKnee }
        var ankle: PoseJoint { self == .left ? .leftAnkle : .rightAnkle }
        var heel: PoseJoint { self == .left ? .leftHeel : .rightHeel }
        var toe: PoseJoint { self == .left ? .leftFootIndex : .rightFootIndex }
        var shoulder: PoseJoint { self == .left ? .leftShoulder : .rightShoulder }

        var opposite: Side { self == .left ? .right : .left }
        var displayName: String { self == .left ? "左足" : "右足" }
    }

    /// 計測結果。
    struct Measurement: Sendable {
        let degrees: Double
        let confidence: Float
        let space: Space
        let convention: Convention

        /// 基準値と比較してよい値かどうか。
        var isComparable: Bool { space == .world }
    }

    private static let visibilityThreshold: Float = 0.5

    // MARK: - 膝屈曲

    /// 膝の屈曲角。**0° = 完全伸展、値が大きいほど深く曲がっている。**
    ///
    /// キーポイントから得られる内角を `180 − 内角` で屈曲角に変換しています。
    /// 文献と PRD の基準値（90〜110°）がこの規約のため、そのまま比較できます。
    ///
    /// 実測（屋外実戦5本）: 90〜113°。室内の軽い蹴り（4本）: 75〜82°。
    static func kneeFlexion(_ frame: PoseFrame, side: Side) -> Measurement? {
        guard let interior = angle(at: side.knee, from: side.hip, to: side.ankle, in: frame) else {
            return nil
        }
        return Measurement(
            degrees: 180 - interior.degrees,
            confidence: interior.confidence,
            space: interior.space,
            convention: .flexion
        )
    }

    /// 膝の内角。局面検出など、生の角度が必要な場面で使う。
    static func kneeInteriorAngle(_ frame: PoseFrame, side: Side) -> Measurement? {
        angle(at: side.knee, from: side.hip, to: side.ankle, in: frame)
    }

    /// **バックスイング最深（屈曲角が最大）のフレーム番号。**
    ///
    /// 屈曲角では「最大」が最も深く曲がった状態です。内角では「最小」でした。
    /// 規約の変更でこの向きが逆転するため、判定を1箇所に集約しています。
    /// 各解析はこの関数を呼ぶこと。
    static func deepestFlexionIndex(
        in sequence: PoseSequence,
        side: Side,
        plausibleRange: ClosedRange<Double> = 0...140
    ) -> Int? {
        var best: (index: Int, degrees: Double)?

        for (index, frame) in sequence.frames.enumerated() {
            guard let m = kneeFlexion(frame, side: side),
                  m.space == .world,
                  m.confidence >= visibilityThreshold,
                  plausibleRange.contains(m.degrees)
            else { continue }

            if best == nil || m.degrees > best!.degrees {
                best = (index, m.degrees)
            }
        }
        return best?.index
    }

    // MARK: - 足関節底屈

    /// 膝→足首→つま先の内角。値が大きいほどつま先が伸びている。
    ///
    /// **規約は内角のままにしています。** 中間位が約90°なので
    /// `底屈角 = 内角 − 90` で換算できますが、この中間位の値は未検証の想定であり、
    /// 変換すると根拠のない数値を提示することになるため保留しています。
    ///
    /// なお本指標は足長の変動係数16〜29%により分解能が不足しており、
    /// 処方には使いません（参考値のみ）。規約の換算では解決しない問題です。
    static func anklePlantarFlexion(_ frame: PoseFrame, side: Side) -> Measurement? {
        angle(at: side.ankle, from: side.knee, to: side.toe, in: frame)
    }

    // MARK: - 体幹前傾

    /// 肩中点→腰中点のベクトルが鉛直から何度傾いているか。**前傾を正、後傾を負**とする。
    ///
    /// 旧実装は `atan2(√(dx²+dz²), |dy|)` で、平方根と絶対値により符号が失われていた。
    /// 前傾13°と後傾13°が同じ値になるため、文献値（Alcock et al. 2012 は
    /// エリート女子で −5.8 ± 8.3°、つまり平均5.8°の**後傾**）と比較できなかった。
    ///
    /// 前方向の決め方: 肩ラインに直交する水平ベクトルを取り、鼻が来る側を前とする。
    /// 肩幅は変動係数4〜6%、鼻の visibility はほぼ1.00で、いずれも安定している。
    static func trunkLean(
        _ frame: PoseFrame,
        forward: (x: Double, z: Double)? = nil
    ) -> Measurement? {
        let joints: [PoseJoint] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        guard let confidence = confidence(of: joints, in: frame) else { return nil }

        guard frame.hasWorld,
              let ls = frame.worldPoint(.leftShoulder), let rs = frame.worldPoint(.rightShoulder),
              let lh = frame.worldPoint(.leftHip), let rh = frame.worldPoint(.rightHip),
              let axis = forward ?? forwardAxis(of: frame)
        else {
            // 3D座標が無い場合、前後の判別ができないため計測不能とする。
            // 符号なしの値を返すと、文献値と比較できない数値が基準値DBに流れ込む。
            return nil
        }

        let dx = Double((ls.x + rs.x) / 2 - (lh.x + rh.x) / 2)
        let dy = Double((ls.y + rs.y) / 2 - (lh.y + rh.y) / 2)
        let dz = Double((ls.z + rs.z) / 2 - (lh.z + rh.z) / 2)

        let forwardComponent = dx * axis.x + dz * axis.z
        let radians = atan2(forwardComponent, abs(dy))
        return Measurement(
            degrees: radians * 180 / .pi,
            confidence: confidence,
            space: .world,
            convention: .fromVertical
        )
    }

    // MARK: - 前方向

    /// 肩ラインに直交する水平方向のうち、鼻が来る側（=体の前）を返す。
    static func forwardAxis(of frame: PoseFrame) -> (x: Double, z: Double)? {
        guard let ls = frame.worldPoint(.leftShoulder),
              let rs = frame.worldPoint(.rightShoulder),
              let nose = frame.worldPoint(.nose)
        else { return nil }

        let ex = Double(rs.x - ls.x), ez = Double(rs.z - ls.z)
        let length = (ex * ex + ez * ez).squareRoot()
        guard length > 1e-6 else { return nil }

        var fx = -ez / length, fz = ex / length
        let sx = Double(ls.x + rs.x) / 2, sz = Double(ls.z + rs.z) / 2
        if (Double(nose.x) - sx) * fx + (Double(nose.z) - sz) * fz < 0 {
            fx = -fx; fz = -fz
        }
        return (fx, fz)
    }

    /// クリップ全体から前方向を1つ決める。フレームごとに求めると
    /// 頭の向きのぶれで符号が反転しうるため、中央値で安定させる。
    static func forwardAxis(of sequence: PoseSequence) -> (x: Double, z: Double)? {
        let axes = sequence.frames.compactMap { forwardAxis(of: $0) }
        guard !axes.isEmpty else { return nil }

        let fx = median(axes.map(\.x))
        let fz = median(axes.map(\.z))
        let length = (fx * fx + fz * fz).squareRoot()
        guard length > 1e-6 else { return nil }
        return (fx / length, fz / length)
    }

    // MARK: - 汎用

    /// 3 点がなす角（頂点 vertex での内角）。
    /// 3D 座標があれば 3D で、無ければ画像座標で計算します。
    static func angle(
        at vertex: PoseJoint,
        from a: PoseJoint,
        to b: PoseJoint,
        in frame: PoseFrame
    ) -> Measurement? {
        guard let confidence = confidence(of: [vertex, a, b], in: frame) else { return nil }

        if let v = frame.worldPoint(vertex),
           let pa = frame.worldPoint(a),
           let pb = frame.worldPoint(b) {
            let v1 = (Double(pa.x - v.x), Double(pa.y - v.y), Double(pa.z - v.z))
            let v2 = (Double(pb.x - v.x), Double(pb.y - v.y), Double(pb.z - v.z))

            let dot = v1.0 * v2.0 + v1.1 * v2.1 + v1.2 * v2.2
            let mag = (v1.0 * v1.0 + v1.1 * v1.1 + v1.2 * v1.2).squareRoot()
                * (v2.0 * v2.0 + v2.1 * v2.1 + v2.2 * v2.2).squareRoot()
            guard mag > 1e-9 else { return nil }

            let cosine = max(-1, min(1, dot / mag))
            return Measurement(
                degrees: acos(cosine) * 180 / .pi,
                confidence: confidence,
                space: .world,
                convention: .interior
            )
        }

        let v = frame[vertex]
        let v1 = (x: Double(frame[a].x - v.x), y: Double(frame[a].y - v.y))
        let v2 = (x: Double(frame[b].x - v.x), y: Double(frame[b].y - v.y))

        let dot = v1.x * v2.x + v1.y * v2.y
        let mag = (v1.x * v1.x + v1.y * v1.y).squareRoot()
            * (v2.x * v2.x + v2.y * v2.y).squareRoot()
        guard mag > 1e-6 else { return nil }

        let cosine = max(-1, min(1, dot / mag))
        return Measurement(
            degrees: acos(cosine) * 180 / .pi,
            confidence: confidence,
            space: .image,
            convention: .interior
        )
    }

    // MARK: - 蹴り足の判定

    /// つま先の移動速度が大きい側を蹴り足とみなす。
    ///
    /// **注意:** 実測でつま先速度は推定が不安定（軸足で 44 m/s という
    /// 物理的にありえない値を観測）。判定が反転する場合があるため、
    /// 現状は自動判定に依存せず、利用側で明示指定することを推奨します。
    static func kickingSide(_ sequence: PoseSequence) -> Side? {
        guard sequence.frames.count > 2 else { return nil }
        let useWorld = sequence.worldCoverage > 0.9

        func peakToeSpeed(_ side: Side) -> Double {
            var peak = 0.0
            for i in 0..<(sequence.frames.count - 1) {
                let a = sequence.frames[i], b = sequence.frames[i + 1]
                let dt = Double(b.timestampMs - a.timestampMs) / 1000
                guard dt > 0,
                      a[side.toe].visibility >= visibilityThreshold,
                      b[side.toe].visibility >= visibilityThreshold
                else { continue }

                let distance: Double
                if useWorld, let p1 = a.worldPoint(side.toe), let p2 = b.worldPoint(side.toe) {
                    let dx = Double(p2.x - p1.x), dy = Double(p2.y - p1.y), dz = Double(p2.z - p1.z)
                    distance = (dx * dx + dy * dy + dz * dz).squareRoot()
                } else {
                    let p1 = a[side.toe], p2 = b[side.toe]
                    let dx = Double(p2.x - p1.x), dy = Double(p2.y - p1.y)
                    distance = (dx * dx + dy * dy).squareRoot()
                }
                let speed = distance / dt
                // 人体としてありえない速度は推定破綻とみなす
                guard speed < 30 else { continue }
                peak = max(peak, speed)
            }
            return peak
        }

        let left = peakToeSpeed(.left), right = peakToeSpeed(.right)
        guard max(left, right) > 0 else { return nil }
        return right > left ? .right : .left
    }

    // MARK: -

    private static func confidence(of joints: [PoseJoint], in frame: PoseFrame) -> Float? {
        var minimum: Float = 1
        for joint in joints {
            let v = frame[joint].visibility
            guard v >= visibilityThreshold else { return nil }
            minimum = min(minimum, v)
        }
        return minimum
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
