import Foundation

/// 骨格推定の破綻を検出し、可能なら補間して修復する。
///
/// **原理**
/// 同一人物の骨の長さは変わりません。クリップ全体の中央値から大きく外れる
/// フレームは、関節の対応付けを誤っている（左右の脚の取り違えなど）と判断できます。
/// 原因を特定しなくても「そのフレームは信用できない」と言えるのが利点です。
///
/// **実測での効果（Phase 0）**
/// 品質ゲート不通過だった6本のうち4本が、補間により通過しました。
/// 通過していたクリップの計測値は変化しません（93°→93°、110°→110°）。
/// 救えなかった2本は、計測窓内の健全フレームが0〜37%しかないものでした。
///
/// **限界**
/// 破綻が計測窓を埋め尽くしている場合は復元できません。情報として
/// 存在しないものは補間できないためです。その場合は撮り直しを案内します。
enum PoseIntegrity {

    /// 骨長がこの割合を超えて中央値から外れたら、そのフレームを破綻とみなす。
    /// 実測では通過クリップで破綻率5〜16%、不通過で8〜27%だった。
    static let lengthTolerance = 0.15

    /// 計測窓内の健全フレームがこの割合を下回ると、診断自体を行わない。
    /// 実測で 11% のクリップでも補間後に妥当な値が得られたため、
    /// 完全に止めるのは情報がほぼ無い場合に限る。
    static let minimumWindowHealthyRatio = 0.10

    /// この割合を下回ると、計測値は出すが処方は控える。
    static let reliablePrescriptionRatio = 0.25

    /// 一貫性を確認する骨。長さが安定している部位のみを使う
    /// （足部は変動係数16〜29%のため対象外）。
    private static let bones: [(PoseJoint, PoseJoint)] = [
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
    ]

    // MARK: - 結果

    struct Result: Sendable {
        /// 補間済みのシーケンス。破綻フレームは前後の健全フレームから内挿されている。
        let repaired: PoseSequence
        /// 元データの各フレームが健全だったか。
        let validity: [Bool]
        /// 補間できなかったフレーム数（前後に健全フレームが無かった場合）。
        let unrepairable: Int

        var brokenCount: Int { validity.filter { !$0 }.count }
        var brokenRatio: Double {
            validity.isEmpty ? 0 : Double(brokenCount) / Double(validity.count)
        }

        /// 指定フレームの前後 windowMs 以内で、元データが健全だった割合。
        func healthyRatio(around index: Int, windowMs: Int) -> Double {
            let frames = repaired.frames
            guard frames.indices.contains(index) else { return 0 }
            let origin = frames[index].timestampMs

            var total = 0, healthy = 0
            for i in frames.indices where abs(frames[i].timestampMs - origin) <= windowMs {
                total += 1
                if validity.indices.contains(i), validity[i] { healthy += 1 }
            }
            return total == 0 ? 0 : Double(healthy) / Double(total)
        }
    }

    // MARK: - 修復

    static func repair(_ sequence: PoseSequence, tolerance: Double = lengthTolerance) -> Result {
        let frames = sequence.frames
        guard frames.count >= 3, sequence.worldCoverage > 0.5 else {
            return Result(
                repaired: sequence,
                validity: Array(repeating: true, count: frames.count),
                unrepairable: 0
            )
        }

        // ── 基準となる骨長（クリップ全体の中央値）
        var reference: [Int: Double] = [:]
        for (index, bone) in bones.enumerated() {
            let lengths = frames.compactMap { length(of: bone, in: $0) }
            guard !lengths.isEmpty else { continue }
            reference[index] = median(lengths)
        }

        // ── 各フレームの健全性
        let validity: [Bool] = frames.map { frame in
            guard frame.hasWorld else { return false }
            for (index, bone) in bones.enumerated() {
                guard let ref = reference[index], ref > 0.05,
                      let actual = length(of: bone, in: frame)
                else { continue }
                if abs(actual - ref) / ref > tolerance { return false }
            }
            return true
        }

        // ── 補間
        var repairedFrames = frames
        var unrepairable = 0

        for i in frames.indices where !validity[i] {
            // 前後の最も近い健全フレームを探す
            var before: Int?
            var index = i - 1
            while index >= 0 {
                if validity[index] { before = index; break }
                index -= 1
            }

            var after: Int?
            index = i + 1
            while index < frames.count {
                if validity[index] { after = index; break }
                index += 1
            }

            switch (before, after) {
            case (nil, nil):
                unrepairable += 1
            case (let b?, nil):
                repairedFrames[i] = copyingCoordinates(from: frames[b], into: frames[i])
            case (nil, let a?):
                repairedFrames[i] = copyingCoordinates(from: frames[a], into: frames[i])
            case (let b?, let a?):
                let span = Double(frames[a].timestampMs - frames[b].timestampMs)
                let weight = span > 0
                    ? Double(frames[i].timestampMs - frames[b].timestampMs) / span
                    : 0.5
                repairedFrames[i] = interpolating(
                    frames[b], frames[a], weight: weight, into: frames[i]
                )
            }
        }

        var repaired = sequence
        repaired.frames = repairedFrames
        if !repaired.engine.hasSuffix("_repaired"), validity.contains(false) {
            repaired.engine += "_repaired"
        }

        return Result(repaired: repaired, validity: validity, unrepairable: unrepairable)
    }

    // MARK: - 撮り直しの案内

    /// 診断を出せなかったときの案内。
    ///
    /// **原因を断定しません。** Phase 0 で光量・履物・カメラ角度・距離・
    /// 動作の速さのいずれも破綻率を説明できませんでした（相関 0.25 前後）。
    /// 断定的な指示より、試せる選択肢を並べる方が誠実です。
    static func retryGuidance(brokenRatio: Double, windowHealthyRatio: Double) -> [String] {
        var items: [String] = []

        if windowHealthyRatio < 0.1 {
            items.append("蹴る瞬間の骨格をほとんど捉えられませんでした。")
        }

        items.append("少し離れて、全身が余裕をもって画面に入るように撮ってみてください。")
        items.append("カメラの位置を変えてみてください（真横／やや斜め前）。")
        items.append("少し力を抑えて蹴ると、捉えやすくなることがあります。")

        if brokenRatio > 0.3 {
            items.append("蹴り足と軸足が重なる場面が長いと、骨格を取り違えやすくなります。立ち位置を少しずらしてみてください。")
        }
        return items
    }

    // MARK: - 補助

    private static func length(of bone: (PoseJoint, PoseJoint), in frame: PoseFrame) -> Double? {
        guard let a = frame.worldPoint(bone.0), let b = frame.worldPoint(bone.1) else { return nil }
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y), dz = Double(a.z - b.z)
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// 座標だけを差し替える。タイムスタンプと visibility は元のまま残す。
    /// visibility を書き換えないのは、そのフレームが不確かだった事実を消さないため。
    private static func copyingCoordinates(from source: PoseFrame, into target: PoseFrame) -> PoseFrame {
        PoseFrame(
            timestampMs: target.timestampMs,
            keypoints: zip(source.keypoints, target.keypoints).map { s, t in
                Keypoint(x: s.x, y: s.y, z: s.z, visibility: t.visibility)
            },
            world: source.world
        )
    }

    private static func interpolating(
        _ before: PoseFrame,
        _ after: PoseFrame,
        weight: Double,
        into target: PoseFrame
    ) -> PoseFrame {
        let w = Float(min(max(weight, 0), 1))

        let keypoints = zip(zip(before.keypoints, after.keypoints), target.keypoints).map {
            pair, original -> Keypoint in
            let (b, a) = pair
            return Keypoint(
                x: b.x + (a.x - b.x) * w,
                y: b.y + (a.y - b.y) * w,
                z: b.z + (a.z - b.z) * w,
                visibility: original.visibility
            )
        }

        var world: [WorldPoint] = []
        if before.hasWorld, after.hasWorld {
            world = zip(before.world, after.world).map { b, a in
                WorldPoint(
                    x: b.x + (a.x - b.x) * w,
                    y: b.y + (a.y - b.y) * w,
                    z: b.z + (a.z - b.z) * w
                )
            }
        }

        return PoseFrame(timestampMs: target.timestampMs, keypoints: keypoints, world: world)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
