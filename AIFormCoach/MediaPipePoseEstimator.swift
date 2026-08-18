import Foundation
import CoreMedia
import MediaPipeTasksVision

/// MediaPipe Pose Landmarker（33点）による実装。
///
/// 画像座標（landmarks）と 3D 座標（worldLandmarks）の両方を取り出します。
/// 角度計算は 3D 側を使うため、worldLandmarks の取得は必須です。
final class MediaPipePoseEstimator: NSObject, PoseEstimating {

    /// モデルの精度と速度のトレードオフ。
    /// 撮影ガイド（F1）のライブ表示は .lite、解析パス（F3〜F5）は .heavy を推奨。
    ///
    /// **3つの .task はすべて `AIFormCoach/` 直下に置いてください。**
    /// このターゲットは Xcode のフォルダ同期（PBXFileSystemSynchronizedRootGroup、
    /// path = AIFormCoach）を使っているため、`AIFormCoach/` に置いたファイルは
    /// 自動でバンドルに入り、それ以外の場所に置いたファイルは pbxproj に個別参照が
    /// 無いので永久にバンドルされません。下の `Bundle.main.path` はディレクトリでは
    /// なくバンドル内の名前で引くため、置き場所を間違えるとビルドは通るのに
    /// 実行時に modelNotFound で落ちます。
    ///
    /// 3ケースとも使用中です（.lite = ライブ、.full = 動画解析の既定、.heavy = 高精度）。
    /// 合計 44.6 MB ありますが、バンドルサイズ削減のために削らないでください。
    /// 減らすならオンデマンドリソース化を検討すること。
    enum Model: String {
        case lite = "pose_landmarker_lite"
        case full = "pose_landmarker_full"
        case heavy = "pose_landmarker_heavy"
    }

    let engineID: String
    var onFrame: ((PoseFrame) -> Void)?

    /// delegate に self を渡す必要があるため、super.init() 後に生成する。
    private var landmarker: PoseLandmarker!
    private let jointCount = PoseJoint.allCases.count

    init(model: Model = .lite) throws {
        guard let path = Bundle.main.path(forResource: model.rawValue, ofType: "task") else {
            throw EstimatorError.modelNotFound(model.rawValue)
        }

        self.engineID = "mediapipe_pose_\(model.rawValue)"
        super.init()

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = .GPU
        options.runningMode = .liveStream
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.poseLandmarkerLiveStreamDelegate = self

        self.landmarker = try PoseLandmarker(options: options)
    }

    func submit(sampleBuffer: CMSampleBuffer, timestampMs: Int) {
        // MPImage は sampleBuffer の場合 kCVPixelFormatType_32BGRA を要求します。
        // CameraCapture 側でこのフォーマットを指定しています。
        guard let image = try? MPImage(sampleBuffer: sampleBuffer) else { return }
        // 処理中のフレームがある場合、MediaPipe 側が新しい入力を自動的に無視します。
        try? landmarker.detectAsync(image: image, timestampInMilliseconds: timestampMs)
    }

    enum EstimatorError: LocalizedError {
        case modelNotFound(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let name):
                return "モデル \(name).task がバンドルに見つかりません。ファイルを追加し、Xcode の Target > Build Phases > Copy Bundle Resources に入っているか確認してください。"
            }
        }
    }
}

// MARK: - 結果の受け取り

extension MediaPipePoseEstimator: PoseLandmarkerLiveStreamDelegate {

    func poseLandmarker(
        _ poseLandmarker: PoseLandmarker,
        didFinishDetection result: PoseLandmarkerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        guard error == nil else { return }

        // 人物が写っていないフレームも、時系列の欠落として残す。
        guard let landmarks = result?.landmarks.first, landmarks.count == jointCount else {
            onFrame?(.empty(timestampMs: timestampInMilliseconds))
            return
        }

        let keypoints = landmarks.map { lm in
            Keypoint(
                x: lm.x,
                y: lm.y,
                z: lm.z,
                visibility: lm.visibility?.floatValue ?? 0
            )
        }

        // 腰の中点を原点としたメートル座標。遠近短縮を受けないので角度計算に使う。
        // 稀に返らないことがあるため、無い場合は空にして 2D にフォールバックさせる。
        var world: [WorldPoint] = []
        if let worldLandmarks = result?.worldLandmarks.first,
           worldLandmarks.count == jointCount {
            world = worldLandmarks.map { WorldPoint(x: $0.x, y: $0.y, z: $0.z) }
        }

        onFrame?(
            PoseFrame(
                timestampMs: timestampInMilliseconds,
                keypoints: keypoints,
                world: world
            )
        )
    }
}
