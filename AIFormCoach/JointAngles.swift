import Foundation
import CoreGraphics

/// PRD §2 ③「自分の数値」に相当する計測部。
///
/// すべて端末内のルールベース計算です。LLM は一切呼びません。
///
/// **3D 座標があるときは必ず 3D で計算します。** 実測で、画像座標で測った
/// 足関節角は撮影角度によって系統的にずれることが確認されました
/// （足長/下腿長 比が 0.21〜1.22 に振れた）。原因は遠近による短縮で、
/// キーポイント自体の誤りではありません。3D 座標はこの影響を受けません。
///
/// 角度の定義を変えると基準値DBの数値が意味を失うので、
/// 定義を変更する場合は必ず `definitionVersion` を上げてください。
enum JointAngles {

    /// 3D 計算への移行に伴い 1 → 2。v1 で測った基準値は再測定が必要です。
    static let definitionVersion = 2

    /// 蹴り足・軸足の左右。
    enum Side: Sendable {
        case left, right

        var hip: PoseJoint { self == .left ? .leftHip : .rightHip }
        var knee: PoseJoint { self == .left ? .leftKnee : .rightKnee }
        var ankle: PoseJoint { self == .left ? .leftAnkle : .rightAnkle }
        var heel: PoseJoint { self == .left ? .leftHeel : .rightHeel }
        var toe: PoseJoint { self == .left ? .leftFootIndex : .rightFootIndex }
        var shoulder: PoseJoint { self == .left ? .leftShoulder : .rightShoulder }

        var opposite: Side { self == .left ? .right : .left }
    }

    /// 計測がどの座標系で行われたか。
    /// 基準値DBに記録し、image のデータを world の基準値と比較しないようにする。
    enum Space: String, Sendable {
        /// 3D メートル座標。遠近短縮の影響を受けない。
        case world
        /// 画像の正規化座標。撮影角度に依存するため参考値。
        case image
    }

    /// 計測結果。visibility が閾値を下回る関節が含まれる場合は nil を返し、
    /// 上位レイヤーで「計測不能」として扱います。
    struct Measurement: Sendable {
        var degrees: Double
        var confidence: Float
        var space: Space

        /// 基準値DBと比較してよい値かどうか。
        var isComparable: Bool { space == .world }
    }

    private static let visibilityThreshold: Float = 0.5

    // MARK: - 膝屈曲

    /// 膝の内角。180° = 完全伸展、値が小さいほど深く折りたたまれている。
    /// PRD の基準値「バックスイング時の膝屈曲 90〜110°」はこの定義。
    static func kneeFlexion(_ frame: PoseFrame, side: Side) -> Measurement? {
        angle(at: side.knee, from: side.hip, to: side.ankle, in: frame)
    }

    // MARK: - 足関節底屈

    /// 膝→足首→つま先の内角。値が大きいほどつま先が伸びている（底屈）。
    ///
    /// **Vision framework では計測できない指標です。**
    /// インステップキックの「足首を固定してつま先を伸ばす」を数値化するには
    /// 足首より先のキーポイントが必要になります。
    ///
    /// 3D でないと意味のある数値になりません。`space == .image` の値は
    /// 撮影角度に依存するため基準値と比較しないでください。
    static func anklePlantarFlexion(_ frame: PoseFrame, side: Side) -> Measurement? {
        angle(at: side.ankle, from: side.knee, to: side.toe, in: frame)
    }

    // MARK: - 体幹前傾

    /// 肩中点→腰中点のベクトルが鉛直から何度傾いているか。
    /// PRD の基準値「体幹前傾 15〜20°」はこの定義。
    ///
    /// 3D で計算する場合、左右への傾き（側屈）と前後の傾きの両方を含んだ
    /// 「鉛直からのずれ」になります。2D では奥行き方向の傾きが失われます。
    static func trunkLean(_ frame: PoseFrame) -> Measurement? {
        let joints: [PoseJoint] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        guard let confidence = confidence(of: joints, in: frame) else { return nil }

        if frame.hasWorld,
           let ls = frame.worldPoint(.leftShoulder), let rs = frame.worldPoint(.rightShoulder),
           let lh = frame.worldPoint(.leftHip), let rh = frame.worldPoint(.rightHip) {

            let dx = Double((ls.x + rs.x) / 2 - (lh.x + rh.x) / 2)
            let dy = Double((ls.y + rs.y) / 2 - (lh.y + rh.y) / 2)
            let dz = Double((ls.z + rs.z) / 2 - (lh.z + rh.z) / 2)

            // 鉛直成分の絶対値からの傾き。軸の符号規約に依存しない形にしてある。
            let horizontal = (dx * dx + dz * dz).squareRoot()
            let radians = atan2(horizontal, abs(dy))
            return Measurement(degrees: radians * 180 / .pi, confidence: confidence, space: .world)
        }

        let shoulder = midpoint(frame[.leftShoulder], frame[.rightShoulder])
        let hip = midpoint(frame[.leftHip], frame[.rightHip])
        let dx = Double(shoulder.x - hip.x)
        let dy = Double(shoulder.y - hip.y)
        let radians = atan2(abs(dx), abs(dy))
        return Measurement(degrees: radians * 180 / .pi, confidence: confidence, space: .image)
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
                space: .world
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
            space: .image
        )
    }

    // MARK: - 蹴り足の判定

    /// つま先の移動速度が大きい側を蹴り足とみなす。
    ///
    /// 実測では蹴り足と軸足でつま先の最大速度に 3〜6 倍の差が出ました
    /// （右 4.21 対 左 0.74 など）。ユーザーに利き足を尋ねる必要はありません。
    static func kickingSide(_ sequence: PoseSequence) -> Side? {
        guard sequence.frames.count > 2 else { return nil }

        func peakToeSpeed(_ side: Side) -> Double {
            var peak = 0.0
            for i in 0..<(sequence.frames.count - 1) {
                let a = sequence.frames[i]
                let b = sequence.frames[i + 1]
                let dt = Double(b.timestampMs - a.timestampMs) / 1000
                guard dt > 0 else { continue }

                let p1 = a[side.toe], p2 = b[side.toe]
                guard p1.visibility >= visibilityThreshold,
                      p2.visibility >= visibilityThreshold else { continue }

                let d = (Double(p2.x - p1.x) * Double(p2.x - p1.x)
                    + Double(p2.y - p1.y) * Double(p2.y - p1.y)).squareRoot()
                peak = max(peak, d / dt)
            }
            return peak
        }

        let left = peakToeSpeed(.left)
        let right = peakToeSpeed(.right)
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

    private static func midpoint(_ a: Keypoint, _ b: Keypoint) -> (x: Float, y: Float) {
        ((a.x + b.x) / 2, (a.y + b.y) / 2)
    }
}
