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
    /// 収録した高フレームレート動画を解析中。
    @Published var isAnalyzingRecording = false

    /// 撮影を停止しているか。
    ///
    /// **シートや別画面を開いている間は必ず true にする。**
    /// これを持たずに「収録結果が無いこと」などの間接的な条件で
    /// 自動開始を抑止していたため、動画解析シートの裏で勝手に収録が
    /// 始まるバグが発生した。停止は明示的な状態として持つ。
    @Published private(set) var isSuspended = false

    /// PRD の 5 秒制限。ここを超えたら自動で収録を終える。
    let maxDurationMs = 5_000

    /// 静止してからこの時間で収録を始める。3 秒 = 「3, 2, 1」の表示。
    let autoStartHoldMs = 3_000

    let camera = CameraCapture()
    private var estimator: PoseEstimating?
    private var recordingStartMs: Int?
    private var stillSinceMs: Int?
    /// 収録中に120fps級のまま実時間で書き出している一時ファイル。
    private var recordingFileURL: URL?
    private var isStarted = false

    // 静止判定用。腰の中点の動きを短い窓で見る。
    private var hipHistory: [(ms: Int, x: Float, y: Float)] = []
    private let stillnessWindowMs = 400
    /// 画面全体を 1.0 としたときの許容ぶれ幅。大きくすると判定が甘くなる。
    private let stillnessThreshold: Float = 0.04

    // MARK: - 起動

    func start() async {
        guard !isStarted else { return }

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
                // 停止中は推論に渡さない。渡すと発熱するだけで意味がない。
                guard let self, !self.isSuspended else { return }
                self.estimator?.submit(sampleBuffer: buffer, timestampMs: ms)
            }
            camera.start()
            isStarted = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        camera.stop()
    }

    // MARK: - 停止と再開

    /// シートや別画面を開くときに呼ぶ。カメラと推論を止め、骨格表示も消す。
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true

        // 収録中に画面が切り替わった場合は、そこまでの分を確定させる。
        if isRecording { finishRecording() }

        camera.stop()
        latestFrame = nil
        resetAutoStart()
    }

    /// 撮影画面に戻ったときに呼ぶ。
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        resetAutoStart()
        camera.start()
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
        guard !isSuspended else { return }
        if isRecording {
            finishRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        recordingStartMs = nil
        recordedSequence = nil
        exportURL = nil
        recordingRemainingMs = maxDurationMs
        resetAutoStart()
        isRecording = true

        // 写真ライブラリ経由のスロー動画は再生時間が水増しされ実時間の計測が
        // できないため、収録中だけ120fps級（非対応機種は自動的に下がる）に切り替え、
        // 実時間のまま自前で書き出す。
        camera.beginHighSpeedCapture()
        recordingFileURL = camera.startFileRecording()
    }

    private func receive(_ frame: PoseFrame) {
        // 停止直後に到着した処理中のフレームを捨てる。
        // 推論は非同期なので、camera.stop() の後にも数枚届きうる。
        guard !isSuspended else { return }

        // インカメラは鏡像なので、関節の左右ラベルを入れ替えてから使う
        let frame = camera.isMirrored ? frame.swappingLeftRight() : frame
        latestFrame = frame

        guard isRecording else {
            updateAutoStart(with: frame)
            return
        }

        if recordingStartMs == nil { recordingStartMs = frame.timestampMs }
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
        camera.endHighSpeedCapture()

        guard recordingFileURL != nil else { return }
        recordingFileURL = nil

        Task {
            guard let savedURL = await camera.stopFileRecording() else {
                errorMessage = "収録データの保存に失敗しました。"
                return
            }
            await analyzeRecording(at: savedURL)
        }
    }

    /// 収録した高フレームレート動画を、実時間を保ったまま高精度モデルで解析する。
    /// 撮影ガイドのライブ表示は .lite だが、解析パスは .heavy を使う
    /// （MediaPipePoseEstimator の方針に合わせる）。
    private func analyzeRecording(at url: URL) async {
        isAnalyzingRecording = true
        defer { isAnalyzingRecording = false }

        do {
            let result = try await VideoPoseAnalyzer().analyze(url: url, model: .heavy)
            // 前面カメラは鏡像なので、背面カメラと同じ座標系へ揃える。
            let frames = camera.isMirrored
                ? result.sequence.frames.map { $0.flippingHorizontally() }
                : result.sequence.frames
            recordedSequence = PoseSequence(frames: frames, engine: result.sequence.engine)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 確認を終えたら破棄する。これを呼ばないと自動開始が再開しない。
    func discardRecording() {
        recordedSequence = nil
        exportURL = nil
    }

    // MARK: - 自動開始（前面カメラのみ）

    /// 全身が画角に入り、かつ静止したら収録を始める。
    /// 背面カメラ（人に撮ってもらう場合）は手動シャッターのままにする。
    private func updateAutoStart(with frame: PoseFrame) {
        guard !isSuspended, camera.isMirrored, recordedSequence == nil, !isExporting else {
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
        if isSuspended || isRecording || isCountingDown { return nil }

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
        guard !isSuspended, let frame = latestFrame else { return [] }
        return [
            ("右膝の曲がり", JointAngles.kneeFlexion(frame, side: .right)),
            ("体幹の前傾", JointAngles.trunkLean(frame)),
            ("右足首の伸び", JointAngles.anklePlantarFlexion(frame, side: .right)),
        ]
    }
}
