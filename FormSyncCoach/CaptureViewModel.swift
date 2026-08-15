import SwiftUI
import AVFoundation
import Combine

@MainActor
final class CaptureViewModel: ObservableObject {

    @Published var latestFrame: PoseFrame?
    @Published var isRecording = false
    @Published var recordedSequence: PoseSequence?
    @Published var exportURL: URL?
    @Published var errorMessage: String?
    @Published var permissionDenied = false
    @Published var isFrontCamera = false

    /// 自動開始までの残り時間（ミリ秒）。nil のときはカウントしていない。
    @Published var autoStartRemainingMs: Int?
    /// 収録の残り時間（ミリ秒）。遠くからでも分かるように大きく表示する。
    @Published var recordingRemainingMs: Int?
    /// 書き出し処理中。
    @Published var isExporting = false

    /// PRD の 5 秒制限。ここを超えたら自動で収録を終える。
    let maxDurationMs = 5_000

    /// 静止してからこの時間で収録を始める。3 秒 = 「3, 2, 1」の表示。
    let autoStartHoldMs = 3_000

    let camera = CameraCapture()
    private var estimator: PoseEstimating?
    private var buffer: [PoseFrame] = []
    private var recordingStartMs: Int?
    private var stillSinceMs: Int?

    // 静止判定用。腰の中点の動きを短い窓で見る。
    private var hipHistory: [(ms: Int, x: Float, y: Float)] = []
    private let stillnessWindowMs = 400
    /// 画面全体を 1.0 としたときの許容ぶれ幅。大きくすると判定が甘くなる。
    private let stillnessThreshold: Float = 0.04

    // MARK: - 起動

    func start() async {
        guard await camera.requestAccess() else {
            permissionDenied = true
            return
        }

        do {
            let estimator = try MediaPipePoseEstimator(model: .lite)
            estimator.onFrame = { [weak self] frame in
                Task { @MainActor in self?.receive(frame) }
            }
            self.estimator = estimator

            try camera.configure(targetFPS: 30, targetWidth: 1280)
            camera.onSampleBuffer = { [weak self] buffer, ms in
                self?.estimator?.submit(sampleBuffer: buffer, timestampMs: ms)
            }
            camera.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        camera.stop()
    }

    // MARK: - カメラ切り替え

    func toggleCamera() {
        do {
            try camera.switchCamera(targetFPS: 30, targetWidth: 1280)
            isFrontCamera = camera.isMirrored
            resetAutoStart()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 収録

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        buffer.removeAll()
        recordingStartMs = nil
        recordedSequence = nil
        exportURL = nil
        recordingRemainingMs = maxDurationMs
        resetAutoStart()
        isRecording = true
    }

    private func receive(_ frame: PoseFrame) {
        // インカメラは鏡像なので、関節の左右ラベルを入れ替えてから使う
        let frame = camera.isMirrored ? frame.swappingLeftRight() : frame
        latestFrame = frame

        guard isRecording else {
            updateAutoStart(with: frame)
            return
        }

        if recordingStartMs == nil { recordingStartMs = frame.timestampMs }
        buffer.append(frame)

        guard let start = recordingStartMs else { return }
        let elapsed = frame.timestampMs - start
        recordingRemainingMs = max(0, maxDurationMs - elapsed)

        if elapsed >= maxDurationMs {
            finishRecording()
        }
    }

    private func finishRecording() {
        isRecording = false
        recordingRemainingMs = nil
        guard let engine = estimator?.engineID, !buffer.isEmpty else { return }

        // 前面カメラは鏡像なので、保存時に座標を反転して背面カメラと同じ座標系へ揃える。
        // これをしないと、前面で撮った骨格と背面で撮った骨格が左右逆向きになり比較できない。
        let frames = camera.isMirrored ? buffer.map { $0.flippingHorizontally() } : buffer
        recordedSequence = PoseSequence(frames: frames, engine: engine)
    }

    /// 確認を終えたら破棄する。これを呼ばないと自動開始が再開しない。
    func discardRecording() {
        recordedSequence = nil
        exportURL = nil
        buffer.removeAll()
    }

    // MARK: - 自動開始（前面カメラのみ）

    /// 全身が画角に入り、かつ静止したら収録を始める。
    /// 背面カメラ（人に撮ってもらう場合）は手動シャッターのままにする。
    private func updateAutoStart(with frame: PoseFrame) {
        guard camera.isMirrored, recordedSequence == nil, !isExporting else {
            resetAutoStart()
            return
        }

        guard frame.isFullBodyInFrame else {
            resetAutoStart()
            return
        }

        guard isStill(frame, at: frame.timestampMs) else {
            stillSinceMs = nil
            autoStartRemainingMs = nil
            return
        }

        if stillSinceMs == nil { stillSinceMs = frame.timestampMs }
        guard let since = stillSinceMs else { return }

        let elapsed = frame.timestampMs - since
        if elapsed >= autoStartHoldMs {
            beginRecording()
        } else {
            autoStartRemainingMs = autoStartHoldMs - elapsed
        }
    }

    /// 腰の中点が短い窓のあいだ動いていないか。
    private func isStill(_ frame: PoseFrame, at ms: Int) -> Bool {
        let x = (frame[.leftHip].x + frame[.rightHip].x) / 2
        let y = (frame[.leftHip].y + frame[.rightHip].y) / 2

        hipHistory.append((ms, x, y))
        hipHistory.removeAll { ms - $0.ms > stillnessWindowMs }

        // 窓が十分に埋まるまでは判定しない
        guard hipHistory.count >= 5,
              let oldest = hipHistory.first,
              ms - oldest.ms >= stillnessWindowMs / 2
        else { return false }

        let xs = hipHistory.map(\.x)
        let ys = hipHistory.map(\.y)
        let spreadX = (xs.max() ?? 0) - (xs.min() ?? 0)
        let spreadY = (ys.max() ?? 0) - (ys.min() ?? 0)

        return spreadX < stillnessThreshold && spreadY < stillnessThreshold
    }

    private func resetAutoStart() {
        stillSinceMs = nil
        autoStartRemainingMs = nil
        hipHistory.removeAll()
    }

    // MARK: - 書き出し

    func export() async {
        guard let sequence = recordedSequence, !isExporting else { return }
        
        isExporting = true
        defer { isExporting = false }
        
        do {
            // 骨格JSONの圧縮は数ミリ秒なのでメインスレッドで十分。
            // 将来ここで動画を書き出すときは SkeletonDocument に nonisolated を付けて
            // Task.detached へ移す。
            exportURL = try SkeletonDocument.write(sequence)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 読み込み（AirDrop / LINE から開かれたとき）

    func open(url: URL) {
        do {
            recordedSequence = try SkeletonDocument.read(from: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 表示用

    var isCountingDown: Bool { autoStartRemainingMs != nil }

    /// カウントダウンに出す数字（3, 2, 1）。
    var countdownSeconds: Int? {
        guard let remaining = autoStartRemainingMs else { return nil }
        return max(1, Int(ceil(Double(remaining) / 1000)))
    }

    /// 収録の残り秒数。
    var recordingSecondsLeft: Int? {
        guard let remaining = recordingRemainingMs else { return nil }
        return max(0, Int(ceil(Double(remaining) / 1000)))
    }

    /// 画面上部に出すガイド文。カウントダウン中と収録中は大きい表示に任せる。
    var guidanceMessage: String? {
        if isRecording || isCountingDown { return nil }

        if isFrontCamera, let frame = latestFrame {
            if !frame.isFullBodyInFrame { return "全身が入るまで下がってください" }
            return "その場で静止してください"
        }

        return confidenceWarning
    }

    /// PRD F3 の低信頼警告。
    var confidenceWarning: String? {
        guard let frame = latestFrame else { return "人物を検出できていません" }
        if frame.coreConfidence < 0.3 { return "全身が映るように離れてください" }
        if frame.coreConfidence < 0.6 { return "明るい場所で、体の正面か真横から撮ってください" }
        return nil
    }

    var liveMeasurements: [(String, JointAngles.Measurement?)] {
        guard let frame = latestFrame else { return [] }
        return [
            ("右膝の曲がり", JointAngles.kneeFlexion(frame, side: .right)),
            ("体幹の前傾", JointAngles.trunkLean(frame)),
            ("右足首の伸び", JointAngles.anklePlantarFlexion(frame, side: .right)),
        ]
    }
}
