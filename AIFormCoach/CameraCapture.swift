import AVFoundation
import SwiftUI
import Combine

/// カメラ入力。MediaPipe が要求する 32BGRA でフレームを出す。
/// 前面 / 背面の切り替えに対応。前面のときは映像を鏡像にする。
final class CameraCapture: NSObject, ObservableObject {

    let session = AVCaptureSession()

    /// 各フレームの CMSampleBuffer と、セッション開始からの経過ミリ秒。
    var onSampleBuffer: ((CMSampleBuffer, Int) -> Void)?

    /// 現在使っているカメラ。
    private(set) var position: AVCaptureDevice.Position = .back

    /// 前面カメラかどうか。映像が鏡像になるため、骨格の左右ラベルを
    /// 入れ替える必要があるかの判断に使う。
    var isMirrored: Bool { position == .front }

    /// 何フレームに1回だけ推論へ渡すか。1 = 全フレーム、2 = 半分。
    /// 発熱が厳しいときだけ 2 以上にする。
    var inferenceStride = 1

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private var startTime: CMTime?
    private var frameCount = 0
    private var lastEmittedMs = -1
    private var device: AVCaptureDevice?

    /// 収録中に試す順番。PRD §4.3の実測により120fps級を仕様値とする
    /// （240fpsは露光時間1/240秒の制約で屋外・体育館での実用性に懸念があり過剰と判断）。
    /// 120fps非対応機種（前面カメラなど）では対応している最大値まで自動的に下がる。
    private let highSpeedFPSCandidates: [Double] = [120, 60]
    private let previewFPS: Double = 30

    // MARK: - 実時間での動画書き出し

    private var isCapturingToFile = false
    private var pendingRecordingURL: URL?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?

    /// 直近で呼ばれたのが start() か stop() か。
    ///
    /// バックグラウンドへ長く置かれた・他アプリ(共有シート経由のFilesなど)に
    /// フォーカスを奪われた場合、iOS 側が `AVCaptureSession` を中断
    /// (`wasInterrupted`)することがある。中断中に `startRunning()` を呼んでも
    /// 実際には開始されず、単に `isRunning` の値だけを信じて「動いている」と
    /// 判断すると、復帰後も見た目は黒いまま固まる。中断が終わった通知を受けて
    /// 「本来動いているべきだったか」をこの値で判断し、必要なら再試行する。
    private var shouldBeRunning = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification, object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
            .flatMap(AVCaptureSession.InterruptionReason.init)
        print("カメラセッションが中断されました: \(String(describing: reason))")
    }

    /// 中断が終わっても `AVCaptureSession` が自動で再開するとは限らない。
    /// 本来動いているはずだったときだけ、明示的に再試行する。
    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        guard shouldBeRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
    }

    /// `.mediaServicesWereReset` はセッションの再構成が必要になる。
    /// 入力/出力を組み直したうえで、動いているべきなら再開する。
    @objc private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        print("カメラセッションで実行時エラー: \(error)")
        guard error.code == .mediaServicesWereReset, shouldBeRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
    }

    // MARK: - 権限

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - セッション構成

    func configure(targetFPS: Double = 30, targetWidth: Int32 = 1280) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // activeFormat を自分で選ぶので preset は使わない。
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) else {
            throw CaptureError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        self.device = device

        // MediaPipe の MPImage(sampleBuffer:) はこのフォーマットを前提にしている。
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // 解析が追いつかない場合は古いフレームを捨てる。遅延より欠落を選ぶ。
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            applyOrientation(to: connection)
        }

        _ = try? applyFormat(fps: targetFPS, width: targetWidth, to: device)
    }

    // MARK: - カメラ切り替え

    /// 前面 / 背面を切り替える。収録中に呼ばないこと。
    func switchCamera(targetFPS: Double = 30, targetWidth: Int32 = 1280) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }

        position = (position == .back) ? .front : .back

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) else {
            throw CaptureError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        self.device = device

        // 入力を差し替えると接続も作り直されるので、設定を再適用する。
        if let connection = output.connection(with: .video) {
            applyOrientation(to: connection)
        }

        _ = try? applyFormat(fps: targetFPS, width: targetWidth, to: device)

        // startTime は意図的にリセットしない。
        // MediaPipe の liveStream モードはタイムスタンプの単調増加を要求するため、
        // ここで 0 に戻すと時間が巻き戻って推論が止まる。
    }

    // MARK: - 向きと鏡像

    /// 向きと鏡像の設定。カメラを切り替えるたびに呼び直す必要がある。
    private func applyOrientation(to connection: AVCaptureConnection) {
        connection.videoRotationAngle = 90

        guard connection.isVideoMirroringSupported else { return }
        // 明示的に false にしないと isVideoMirrored の代入で例外が出る。
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = (position == .front)
    }

    // MARK: - フォーマット選択

    /// 目標を満たす中で「最小の」解像度を選ぶ。
    /// MediaPipe は内部で 256px 程度に縮小するため、これ以上大きくしても
    /// 精度は上がらず発熱だけ増える。
    @discardableResult
    private func applyFormat(fps: Double, width: Int32, to device: AVCaptureDevice) throws -> Bool {
        let candidates = device.formats.filter { format in
            let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dim.width >= width
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }

        guard let best = candidates.min(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else { return false }

        let dim = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("選択したフォーマット: \(dim.width)x\(dim.height) @ \(fps)fps / \(position == .front ? "前面" : "背面")")

        try device.lockForConfiguration()
        device.activeFormat = best
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        return true
    }

    // MARK: - 収録中だけ高フレームレートにする

    /// 収録の直前に呼ぶ。120fps → 60fps の順に、機種が対応している
    /// 最大値を選ぶ。写真ライブラリ経由のスロー動画は再生時間が水増しされて
    /// 実時間の計測ができないため、自前でこの高フレームレートのまま
    /// `startFileRecording()` で書き出す。
    func beginHighSpeedCapture(width: Int32 = 1280) {
        guard let device else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for fps in highSpeedFPSCandidates {
            if let applied = try? applyFormat(fps: fps, width: width, to: device), applied {
                return
            }
        }
    }

    /// 収録が終わったらプレビュー用の通常フレームレートへ戻す。
    func endHighSpeedCapture(width: Int32 = 1280) {
        guard let device else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        _ = try? applyFormat(fps: previewFPS, width: width, to: device)
    }

    // MARK: - 開始 / 停止

    /// `session.isRunning` をメインスレッドで読んでから非同期でキューに投げる
    /// 形は使わない。start/stop を短時間に連続で呼ぶと(ホームへ戻ってすぐ
    /// 戻る操作で起きる)、先の stop がキュー上でまだ実行されていないうちに
    /// あとの start が「もう動いている」と誤認してエンキューされず消える。
    /// 結果、遅れて実行された stop だけが効いてカメラが停止したまま
    /// 戻らなくなる。start/stop 自体は Apple のドキュメント通り冗長に呼んでも
    /// 安全なので、判定なしで必ずキューに積み、シリアルキューの実行順に委ねる。
    func start() {
        shouldBeRunning = true
        queue.async { [weak self] in self?.session.startRunning() }
    }

    func stop() {
        shouldBeRunning = false
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    // MARK: - 実時間での動画書き出し（120fps級収録用）

    /// 実際のカメラ映像を実時間のまま一時ファイル(.mov)に書き出す準備をする。
    /// 書き出し自体は最初のフレームが来た時点（`appendToFileRecording`）で
    /// 実サイズが分かってから始める。
    func startFileRecording() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture_\(UUID().uuidString).mov")
        pendingRecordingURL = url
        assetWriter = nil
        assetWriterInput = nil
        isCapturingToFile = true
        return url
    }

    /// 書き出しを終える。呼び出し元は返ってきた URL を
    /// `VideoPoseAnalyzer` にそのまま渡せば、実時間のまま解析できる。
    func stopFileRecording() async -> URL? {
        isCapturingToFile = false
        guard let writer = assetWriter, let input = assetWriterInput else {
            assetWriter = nil
            assetWriterInput = nil
            pendingRecordingURL = nil
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        assetWriter = nil
        assetWriterInput = nil
        let url = pendingRecordingURL
        pendingRecordingURL = nil
        return writer.status == .completed ? url : nil
    }

    /// `queue`（カメラのシリアルキュー）上で呼ばれる想定。
    /// 最初の1フレームが来た時点で、実際のピクセルサイズに合わせて
    /// AVAssetWriter を組み立てる（回転後のサイズは事前に分からないため）。
    private func appendToFileRecording(_ sampleBuffer: CMSampleBuffer) {
        if assetWriter == nil {
            guard let url = pendingRecordingURL,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
            else { return }

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
                AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer),
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return }
            writer.add(input)

            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            assetWriter = writer
            assetWriterInput = input
        }

        guard let input = assetWriterInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: -

    enum CaptureError: LocalizedError {
        case noCamera, cannotAddInput, cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera:
                return "カメラが見つかりません。シミュレータではなく実機で実行してください。"
            case .cannotAddInput, .cannotAddOutput:
                return "カメラセッションの構成に失敗しました。"
            }
        }
    }
}

// MARK: - フレーム出力

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if isCapturingToFile { appendToFileRecording(sampleBuffer) }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil { startTime = pts }
        guard let start = startTime else { return }

        frameCount += 1
        guard frameCount % inferenceStride == 0 else { return }

        // MediaPipe の liveStream モードはタイムスタンプの単調増加を要求する。
        let elapsed = CMTimeSubtract(pts, start)
        var ms = Int(CMTimeGetSeconds(elapsed) * 1000)
        // 停止・再開でタイムスタンプが巻き戻ると MediaPipe の推論が止まるため、
        // 単調増加を保証する。
        if ms <= lastEmittedMs { ms = lastEmittedMs + 1 }
        lastEmittedMs = ms
        onSampleBuffer?(sampleBuffer, ms)
    }
}

// MARK: - SwiftUI プレビュー

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
