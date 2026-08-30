import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - 写真ライブラリから動画を受け取る

/// PhotosPicker が返す動画を一時ファイルとして受け取るための型。
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // 受け取ったファイルは一時的なものなので、自分の領域へコピーしてから使う。
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("import_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(url: destination)
        }
    }
}

// MARK: - 画面

struct VideoAnalysisView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var pickedItem: PhotosPickerItem?
    @State private var model: VideoPoseAnalyzer.ModelFile = .full
    @State private var phase: Phase = .idle
    @State private var progress: Double = 0
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var kickingSide: JointAngles.Side = .right

    private enum Phase {
        case idle
        case analyzing
        case done(VideoAnalysisResult)
    }

    private var availableModels: [VideoPoseAnalyzer.ModelFile] {
        VideoPoseAnalyzer.ModelFile.allCases.filter(\.isAvailable)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("動画から骨格をつくる")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") {
                            task?.cancel()
                            dismiss()
                        }
                    }
                }
                .alert("エラー", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK") { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
                .sheet(item: $exportURL) { url in
                    ShareSheet(items: [url])
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            picker
        case .analyzing:
            analyzing
        case .done(let result):
            resultView(result)
        }
    }

    // MARK: 選択画面

    private var picker: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "figure.kickboxing")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("撮影済みの動画を選んでください")
                    .font(.headline)
                Text("標準カメラアプリのスローモーション撮影で撮った動画なら、キックの瞬間まで捉えられます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            if availableModels.count > 1 {
                Picker("精度", selection: $model) {
                    ForEach(availableModels, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 32)
            }

            PhotosPicker(
                selection: $pickedItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                Label("動画を選ぶ", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)

            Spacer()
        }
        .onAppear {
            // 高精度モデルが入っていればそれを既定にする。
            if VideoPoseAnalyzer.ModelFile.heavy.isAvailable { model = .heavy }
            else if VideoPoseAnalyzer.ModelFile.full.isAvailable { model = .full }
            else { model = .lite }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            startAnalysis(item)
        }
    }

    // MARK: 解析中

    private var analyzing: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: progress) {
                Text("解析しています")
                    .font(.headline)
            } currentValueLabel: {
                Text("\(Int(progress * 100))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)

            Text("全フレームを1枚ずつ処理しています。長い動画や高精度モデルでは時間がかかります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("中止") {
                task?.cancel()
                phase = .idle
                pickedItem = nil
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    // MARK: 結果

    private func resultView(_ result: VideoAnalysisResult) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                diagnostics(result)

                Picker("蹴り足", selection: $kickingSide) {
                    Text("右足で蹴った").tag(JointAngles.Side.right)
                    Text("左足で蹴った").tag(JointAngles.Side.left)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                SkeletonPlayer(sequence: result.sequence)

                NavigationLink {
                    DiagnosisDestination(sequence: result.sequence, side: kickingSide)
                } label: {
                    Label("診断を見る", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)

                Button {
                    export(result.sequence)
                } label: {
                    Label(".fsc に書き出す", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isExporting)
                .padding(.horizontal)

                Button("別の動画を選ぶ") {
                    phase = .idle
                    pickedItem = nil
                    progress = 0
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 32)
            }
        }
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    ProgressView().controlSize(.large)
                }
            }
        }
    }


    /// 解析の妥当性を判断するための数値。ここを見て撮影方法を決める。
    private func diagnostics(_ r: VideoAnalysisResult) -> some View {
        VStack(spacing: 0) {
            row("動画の公称fps", String(format: "%.0f", r.nominalFPS))
            Divider()
            row("実際に解析できたfps", String(format: "%.1f", r.analyzedFPS), emphasize: true)
            Divider()
            row("解析フレーム数", "\(r.analyzedFrames)")
            Divider()
            row("人物を検出できた割合", String(format: "%.0f%%", r.detectionRate * 100))
            Divider()
            row("3D座標が得られた割合", String(format: "%.0f%%", r.worldCoverage * 100))
            Divider()
            row(
                "膝角の最大変化",
                String(format: "%.0f°/frame", r.maxKneeDeltaPerFrame),
                emphasize: true,
                warning: r.maxKneeDeltaPerFrame > 20
            )
            Divider()
            row("蹴り足", r.kickingSide.map { $0 == .right ? "右" : "左" } ?? "判定できず")
            Divider()
            row(
                "体の縦横比",
                String(format: "%.2f", r.bodyAspectRatio),
                emphasize: true,
                warning: r.orientationLooksWrong
            )
            Divider()
            row("解像度", "\(r.width)x\(r.height)")
            Divider()
            row("長さ", String(format: "%.2f 秒", r.durationSeconds))
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func row(
        _ label: String,
        _ value: String,
        emphasize: Bool = false,
        warning: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(emphasize ? .callout.bold().monospacedDigit() : .callout.monospacedDigit())
                .foregroundStyle(warning ? .orange : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: 処理

    private func startAnalysis(_ item: PhotosPickerItem) {
        phase = .analyzing
        progress = 0

        task = Task {
            do {
                guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                    throw VideoPoseAnalyzer.AnalyzerError.noVideoTrack
                }

                let analyzer = VideoPoseAnalyzer()
                let result = try await analyzer.analyze(
                    url: video.url,
                    model: model,
                    progress: { value in
                        Task { @MainActor in progress = value }
                    }
                )

                if let detected = result.kickingSide { kickingSide = detected }
                // ライブ収録と同じく、解析できた時点で保存する。標準カメラで
                // 撮った自分の動画を取り込むケースが主眼なので .recorded とする。
                // 保存に失敗しても解析結果の表示は進めたいので、外側の catch
                // (中止/失敗時に phase を .idle に戻す)には流さない。
                do {
                    try SkeletonLibrary.shared.save(result.sequence, source: .recorded)
                } catch {
                    errorMessage = error.localizedDescription
                }
                phase = .done(result)
            } catch is CancellationError {
                phase = .idle
                pickedItem = nil
            } catch {
                errorMessage = error.localizedDescription
                phase = .idle
                pickedItem = nil
            }
        }
    }

    private func export(_ sequence: PoseSequence) {
        isExporting = true
        defer { isExporting = false }
        do {
            exportURL = try SkeletonDocument.write(sequence, name: "video_skeleton")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
