import Foundation
import CoreGraphics

// MARK: - 関節定義

/// MediaPipe Pose Landmarker の 33 キーポイント。
///
/// raw value は MediaPipe の出力インデックスと一対一で対応しています。
/// **順序は絶対に変更しないでください。** 基準値DBに保存した角度が
/// このインデックスを前提に計算されているためです。
enum PoseJoint: Int, CaseIterable, Codable, Sendable {
    case nose = 0
    case leftEyeInner, leftEye, leftEyeOuter
    case rightEyeInner, rightEye, rightEyeOuter
    case leftEar, rightEar
    case mouthLeft, mouthRight
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftPinky, rightPinky
    case leftIndex, rightIndex
    case leftThumb, rightThumb
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
    case leftHeel, rightHeel          // ← Vision framework には存在しない
    case leftFootIndex, rightFootIndex // ← Vision framework には存在しない

    /// 左右を入れ替えた対応する関節。鏡像映像の補正に使う。
    /// MediaPipe のインデックスは 1↔4, 2↔5, 3↔6、7 以降は奇数=左 / 偶数=右 で並んでいる。
    var mirrored: PoseJoint {
        switch rawValue {
        case 0: return self                                   // 鼻は左右なし
        case 1...3: return PoseJoint(rawValue: rawValue + 3)! // 左目 → 右目
        case 4...6: return PoseJoint(rawValue: rawValue - 3)! // 右目 → 左目
        default: return PoseJoint(rawValue: rawValue % 2 == 1 ? rawValue + 1 : rawValue - 1)!
        }
    }

    /// 骨格描画のための接続ペア。顔の細かい点は描画しない。
    static let bones: [(PoseJoint, PoseJoint)] = [
        // 体幹
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip), (.leftHip, .rightHip),
        // 腕
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        // 脚
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        // 足部（キック動作の要）
        (.leftAnkle, .leftHeel), (.leftHeel, .leftFootIndex),
        (.leftAnkle, .leftFootIndex),
        (.rightAnkle, .rightHeel), (.rightHeel, .rightFootIndex),
        (.rightAnkle, .rightFootIndex),
    ]
}

// MARK: - キーポイント

/// 画像上の正規化座標。描画と画角判定に使う。x, y は 0...1（左上原点）。
struct Keypoint: Sendable, Equatable {
    var x: Float
    var y: Float
    /// 腰の中点を基準とした相対深度。単位は x と同スケールで、metric ではない。
    var z: Float
    /// 0...1。低い値は遮蔽や画角外を示す。PRD F3 の「低信頼警告」に使う。
    var visibility: Float

    var point: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

/// MediaPipe の worldLandmarks。腰の中点を原点とした**メートル単位**の3次元座標。
///
/// 画像座標と違い遠近による短縮（foreshortening）を受けないため、
/// 角度計算はこちらを使います。実測で、足関節角を画像座標で測ると
/// 撮影角度によって系統的にずれることが確認されています。
struct WorldPoint: Sendable, Equatable {
    var x: Float
    var y: Float
    var z: Float
}

/// 1 フレーム分の骨格。
struct PoseFrame: Sendable {
    /// 撮影開始からの経過時間（ミリ秒）。
    var timestampMs: Int
    /// 常に 33 要素。未検出フレームは visibility 0 で埋める。
    var keypoints: [Keypoint]
    /// 33 要素、または空。空の場合は 3D 情報なし（v1 の古いファイルなど）。
    var world: [WorldPoint] = []

    subscript(joint: PoseJoint) -> Keypoint {
        keypoints[joint.rawValue]
    }

    /// 3D 座標が利用できるか。
    var hasWorld: Bool { world.count == PoseJoint.allCases.count }

    /// 3D 座標。無い場合は nil。
    func worldPoint(_ joint: PoseJoint) -> WorldPoint? {
        guard hasWorld else { return nil }
        return world[joint.rawValue]
    }

    /// PRD F3 の低信頼警告用。主要関節の平均 visibility。
    var coreConfidence: Float {
        let core: [PoseJoint] = [
            .leftShoulder, .rightShoulder, .leftHip, .rightHip,
            .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
        ]
        let sum = core.reduce(Float(0)) { $0 + self[$1].visibility }
        return sum / Float(core.count)
    }

    /// 全身が画角に収まっているか。
    ///
    /// MediaPipe は画角の外にある関節も位置を推測して返してくるため、
    /// visibility だけでは判定できません。座標が枠内にあることも確認します。
    var isFullBodyInFrame: Bool {
        let required: [PoseJoint] = [
            .nose,
            .leftShoulder, .rightShoulder,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle,
            .leftFootIndex, .rightFootIndex,
        ]
        let margin: Float = 0.02

        for joint in required {
            let kp = self[joint]
            guard kp.visibility >= 0.6 else { return false }
            guard kp.x > margin, kp.x < 1 - margin,
                  kp.y > margin, kp.y < 1 - margin else { return false }
        }
        return true
    }

    /// 鏡像映像から得た骨格の左右ラベルを入れ替える。
    /// 座標は鏡像空間のままにする（プレビューと重なりを合わせるため）。
    func swappingLeftRight() -> PoseFrame {
        var swappedKeypoints = keypoints
        for joint in PoseJoint.allCases {
            swappedKeypoints[joint.rawValue] = keypoints[joint.mirrored.rawValue]
        }

        var swappedWorld = world
        if hasWorld {
            for joint in PoseJoint.allCases {
                swappedWorld[joint.rawValue] = world[joint.mirrored.rawValue]
            }
        }

        return PoseFrame(
            timestampMs: timestampMs,
            keypoints: swappedKeypoints,
            world: swappedWorld
        )
    }

    /// 左右を反転する。鏡像カメラで撮ったデータを、
    /// 他人が見たままの座標系（背面カメラと同じ）に揃えるために使う。
    /// 画像座標は 1-x、3D 座標は符号反転になる点に注意。
    func flippingHorizontally() -> PoseFrame {
        PoseFrame(
            timestampMs: timestampMs,
            keypoints: keypoints.map {
                Keypoint(x: 1 - $0.x, y: $0.y, z: $0.z, visibility: $0.visibility)
            },
            world: world.map { WorldPoint(x: -$0.x, y: $0.y, z: $0.z) }
        )
    }

    static func empty(timestampMs: Int) -> PoseFrame {
        PoseFrame(
            timestampMs: timestampMs,
            keypoints: Array(
                repeating: Keypoint(x: 0, y: 0, z: 0, visibility: 0),
                count: PoseJoint.allCases.count
            ),
            world: []
        )
    }
}

/// 一連の撮影で得られた骨格の時系列。
struct PoseSequence: Sendable {
    var frames: [PoseFrame] = []
    /// 推定に使ったエンジンの識別子。将来エンジンを差し替えたとき、
    /// どの基準値を再測定すべきか判断するために必ず記録する。
    var engine: String
    var recordedAt: Date = .init()

    var durationMs: Int {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.timestampMs - first.timestampMs
    }

    var averageFPS: Double {
        guard frames.count > 1, durationMs > 0 else { return 0 }
        return Double(frames.count - 1) / (Double(durationMs) / 1000.0)
    }

    /// 3D 座標を持つフレームの割合。1.0 なら全フレームで 3D 計測ができる。
    var worldCoverage: Double {
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter(\.hasWorld).count) / Double(frames.count)
    }
}
