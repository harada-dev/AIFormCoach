import AVFoundation
import CoreMedia
import MediaPipeTasksVision
import UIKit

// MARK: - 解析結果

/// 動画1本を解析した結果。
struct VideoAnalysisResult: Sendable {
    var sequence: PoseSequence
    var nominalFPS: Double
    var analyzedFrames: Int
    var detectedFrames: Int
    var durationSeconds: Double
    /// 回転を適用した後のサイズ。縦向き動画なら縦長になる。
    var width: Int
    var height: Int
    var modelName: String

    /// 骨格の縦の広がり ÷ 横の広がり（検出フレームの中央値）。
    ///
    /// 立っている人なら 1.5 以上になります。**1 を下回る場合は
    /// 映像の向きが 90 度ずれている疑いが濃厚です。**
    /// 実測で、向きがずれた動画では 0.47 になりました。
    var bodyAspectRatio: Double

    var orientationLooksWrong: Bool { bodyAspectRatio > 0 && bodyAspectRatio < 1.0 }

    var analyzedFPS: Double {
        durationSeconds > 0 ? Double(analyzedFrames) / durationSeconds : 0
    }

    var detectionRate: Double {
        analyzedFrames > 0 ? Double(detectedFrames) / Double(analyzedFrames) : 0
    }

    var worldCoverage: Double { sequence.worldCoverage }

    /// 膝角の1フレームあたり最大変化量。時間解像度の十分さを示す。
    /// 30fps では 64°/frame を観測しており、インパクト時の角度が測れていませんでした。
    var maxKneeDeltaPerFrame: Double {
        guard let side = JointAngles.kickingSide(sequence) else { return 0 }
        var previous: Double?
        var maximum = 0.0
        for frame in sequence.frames {
            guard let m = JointAngles.kneeFlexion(frame, side: side) else {
                previous = nil
                continue
            }
            if let p = previous { maximum = max(maximum, abs(m.degrees - p)) }
            previous = m.degrees
        }
        return maximum
    }

    var kickingSide: JointAngles.Side? { JointAngles.kickingSide(sequence) }
}

// MARK: - 解析器

/// 録画済み動画を1フレームずつ骨格推定にかける。
///
/// **回転の扱いについて**
/// iPhone で縦向きに撮った動画は、ピクセルデータは横向きに保存され、
/// `preferredTransform` で 90 度回して表示する構造になっています。
/// MediaPipe の `MPImage(sampleBuffer:orientation:)` はこの向き指定を
/// 反映してくれないため、`AVVideoComposition` でピクセル自体を回転させてから
/// 渡します。こうすると MediaPipe には常に回転済みの画像が渡ります。
final class VideoPoseAnalyzer {

    enum ModelFile: String, CaseIterable, Sendable {
        case lite = "pose_landmarker_lite"
        case full = "pose_landmarker_full"
        case heavy = "pose_landmarker_heavy"

        var displayName: String {
            switch self {
            case .lite: return "軽量（速い）"
            case .full: return "標準"
            case .heavy: return "高精度（遅い）"
            }
        }

        var isAvailable: Bool {
            Bundle.main.path(forResource: rawValue, ofType: "task") != nil
        }
    }

    func analyze(
        url: URL,
        model: ModelFile = .heavy,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoAnalysisResult {

        guard let modelPath = Bundle.main.path(forResource: model.rawValue, ofType: "task") else {
            throw AnalyzerError.modelNotFound(model.rawValue)
        }

        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzerError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let nominalFPS = Double(try await sourceTrack.load(.nominalFrameRate))
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let transform = try await sourceTrack.load(.preferredTransform)

        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw AnalyzerError.emptyVideo
        }

        // MARK: 回転を適用したコンポジションを組む

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AnalyzerError.readerSetupFailed
        }
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )

        // preferredTransform は回転に加えて必要な平行移動も含んでいるので、
        // そのまま適用して、描画サイズだけ回転後の寸法に合わせる。
        let rotatedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        // ここを 1/30 に固定すると 240fps 動画からフレームが間引かれてしまう。
        // 動画本来のフレームレートに合わせる。
        let outputFPS = nominalFPS > 0 ? nominalFPS : 30
        videoComposition.frameDuration = CMTime(
            seconds: 1.0 / outputFPS,
            preferredTimescale: 600_000
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        print("""
        動画解析を開始
          元サイズ \(Int(naturalSize.width))x\(Int(naturalSize.height))
          回転後   \(Int(renderSize.width))x\(Int(renderSize.height))
          公称fps \(String(format: "%.2f", nominalFPS))
          長さ \(String(format: "%.2f", durationSeconds))秒
          transform [a:\(transform.a) b:\(transform.b) c:\(transform.c) d:\(transform.d) tx:\(transform.tx) ty:\(transform.ty)]
          モデル \(model.rawValue)
        """)

        // MARK: リーダー

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalyzerError.readerSetupFailed }
        reader.add(output)

        guard reader.startReading() else {
            throw AnalyzerError.readerFailed(reader.error?.localizedDescription ?? "不明なエラー")
        }

        // MARK: 推論器

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.baseOptions.delegate = .GPU
        options.runningMode = .video
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5

        let landmarker = try PoseLandmarker(options: options)
        let jointCount = PoseJoint.allCases.count

        // MARK: フレームループ

        var frames: [PoseFrame] = []
        var analyzed = 0
        var detected = 0
        var lastMs = -1
        var aspectSamples: [Double] = []

        while reader.status == .reading {
            try Task.checkCancellation()

            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }

            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard seconds.isFinite else { continue }

            // MediaPipe はタイムスタンプの単調増加を要求する。
            // 240fps では 1 フレーム 4.2ms なので、ミリ秒に丸めると衝突しうる。
            var ms = Int((seconds * 1000).rounded())
            if ms <= lastMs { ms = lastMs + 1 }
            lastMs = ms

            analyzed += 1

            // ピクセルはすでに正しい向きに回転済みなので、向きの指定は不要。
            guard let image = try? MPImage(sampleBuffer: sample) else {
                frames.append(.empty(timestampMs: ms))
                continue
            }

            let result = try? landmarker.detect(videoFrame: image, timestampInMilliseconds: ms)

            guard let landmarks = result?.landmarks.first, landmarks.count == jointCount else {
                frames.append(.empty(timestampMs: ms))
                continue
            }
            detected += 1

            let keypoints = landmarks.map {
                Keypoint(x: $0.x, y: $0.y, z: $0.z, visibility: $0.visibility?.floatValue ?? 0)
            }

            var world: [WorldPoint] = []
            if let worldLandmarks = result?.worldLandmarks.first,
               worldLandmarks.count == jointCount {
                world = worldLandmarks.map { WorldPoint(x: $0.x, y: $0.y, z: $0.z) }
            }

            let frame = PoseFrame(timestampMs: ms, keypoints: keypoints, world: world)
            frames.append(frame)

            if let aspect = Self.bodyAspect(of: frame) { aspectSamples.append(aspect) }

            if analyzed % 15 == 0 {
                progress?(min(1, seconds / durationSeconds))
                await Task.yield()
            }
        }

        if reader.status == .failed {
            throw AnalyzerError.readerFailed(
                reader.error?.localizedDescription ?? "読み込みに失敗しました"
            )
        }
        guard !frames.isEmpty else { throw AnalyzerError.noFramesDecoded }

        progress?(1)

        let aspect = aspectSamples.isEmpty ? 0 : Self.median(aspectSamples)

        print("""
        解析完了
          解析フレーム \(analyzed) / 検出 \(detected)
          実測fps \(String(format: "%.1f", Double(analyzed) / durationSeconds))
          体の縦横比 \(String(format: "%.2f", aspect))\(aspect > 0 && aspect < 1.0 ? "  ← 向きがずれている疑い" : "")
        """)

        return VideoAnalysisResult(
            sequence: PoseSequence(
                frames: frames,
                engine: "mediapipe_pose_\(model.rawValue)_video"
            ),
            nominalFPS: nominalFPS,
            analyzedFrames: analyzed,
            detectedFrames: detected,
            durationSeconds: durationSeconds,
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            modelName: model.rawValue,
            bodyAspectRatio: aspect
        )
    }

    // MARK: - 向きの自己診断

    /// 骨格の縦の広がりを横の広がりで割った値。
    /// 立っている人なら 1.5 以上。1 未満なら映像が横倒しになっている。
    private static func bodyAspect(of frame: PoseFrame) -> Double? {
        let joints: [PoseJoint] = [
            .nose, .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftAnkle, .rightAnkle,
        ]
        let visible = joints.map { frame[$0] }
        guard visible.allSatisfy({ $0.visibility >= 0.5 }) else { return nil }

        let xs = visible.map { Double($0.x) }
        let ys = visible.map { Double($0.y) }
        let horizontal = (xs.max() ?? 0) - (xs.min() ?? 0)
        let vertical = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard horizontal > 1e-6 else { return nil }
        return vertical / horizontal
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    // MARK: -

    enum AnalyzerError: LocalizedError {
        case modelNotFound(String)
        case noVideoTrack
        case emptyVideo
        case readerSetupFailed
        case readerFailed(String)
        case noFramesDecoded

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let name):
                return "モデル \(name).task がバンドルにありません。ファイルを追加し、Build Phases の Copy Bundle Resources に入っているか確認してください。"
            case .noVideoTrack:
                return "この動画には映像トラックがありません。"
            case .emptyVideo:
                return "動画の長さを取得できませんでした。"
            case .readerSetupFailed:
                return "動画リーダーの構成に失敗しました。"
            case .readerFailed(let message):
                return "動画の読み込みに失敗しました：\(message)"
            case .noFramesDecoded:
                return "フレームを1枚も取り出せませんでした。動画の形式が対応していない可能性があります。"
            }
        }
    }
}
