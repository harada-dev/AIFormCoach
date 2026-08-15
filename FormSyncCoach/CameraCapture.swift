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

        try? applyFormat(fps: targetFPS, width: targetWidth, to: device)
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

        // 入力を差し替えると接続も作り直されるので、設定を再適用する。
        if let connection = output.connection(with: .video) {
            applyOrientation(to: connection)
        }

        try? applyFormat(fps: targetFPS, width: targetWidth, to: device)

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
    private func applyFormat(fps: Double, width: Int32, to device: AVCaptureDevice) throws {
        let candidates = device.formats.filter { format in
            let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dim.width >= width
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }

        guard let best = candidates.min(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else { return }

        let dim = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("選択したフォーマット: \(dim.width)x\(dim.height) @ \(fps)fps / \(position == .front ? "前面" : "背面")")

        try device.lockForConfiguration()
        device.activeFormat = best
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    // MARK: - 開始 / 停止

    func start() {
        guard !session.isRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
    }

    func stop() {
        guard session.isRunning else { return }
        queue.async { [weak self] in self?.session.stopRunning() }
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
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil { startTime = pts }
        guard let start = startTime else { return }

        frameCount += 1
        guard frameCount % inferenceStride == 0 else { return }

        // MediaPipe の liveStream モードはタイムスタンプの単調増加を要求する。
        let elapsed = CMTimeSubtract(pts, start)
        let ms = Int(CMTimeGetSeconds(elapsed) * 1000)
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
