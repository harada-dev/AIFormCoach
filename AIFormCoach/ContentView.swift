import SwiftUI
import UniformTypeIdentifiers

@main
struct AIFormCoachApp: App {
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // AirDrop / LINE から .fsc ファイルを開いたとき
                .onOpenURL { url in model.open(url: url) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: CaptureViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false
    @State private var showingVideoAnalysis = false
    @State private var showingLibrary = false

    var body: some View {
        ZStack {
            if model.isSuspended {
                Color.black.ignoresSafeArea()
            } else {
                CameraPreview(session: model.camera.session)
                    .ignoresSafeArea()

                SkeletonOverlay(frame: model.latestFrame)
                    .ignoresSafeArea()
            }

            // 収録中は画面の縁を赤く光らせる。数メートル離れても分かる。
            if model.isRecording {
                RecordingBorder()
            }

            // 静止後のカウントダウン。3, 2, 1 を大きく出す。
            if let seconds = model.countdownSeconds {
                CountdownNumber(seconds: seconds)
            }

            // 収録した高フレームレート動画を解析している間の表示。
            if model.isAnalyzingRecording {
                AnalyzingOverlay()
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding()
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.recordedSequence != nil) { _, hasSequence in
            if hasSequence { showingPlayer = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // アプリが背面に回ったときも止める。発熱とバッテリーの節約になる。
            // 解析中や確認シート表示中は別の理由で止まっているので、
            // ここでは前面かどうかだけを見ればよい。以前はこの分岐が
            // 他の停止理由を条件で列挙していて、解析中を取りこぼしていた。
            if phase == .active {
                model.resume(.background)
            } else {
                model.suspend(.background)
            }
        }
        .sheet(isPresented: $showingPlayer, onDismiss: { model.discardRecording() }) {
            // このシートの停止（.reviewing）は recordedSequence の有無に紐づけて
            // CaptureViewModel 側が持っている。シートのライフサイクルに紐づけると、
            // 解析完了からシート表示までの隙間でカメラが一瞬 ON に戻る。
            reviewSheet
        }
        .alert("エラー", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("カメラを使えません", isPresented: $model.permissionDenied) {
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("あとで", role: .cancel) {}
        } message: {
            Text("設定アプリでカメラへのアクセスを許可してください。")
        }
    }

    // MARK: - 収録後の確認画面

    /// 共有シートはこのシートの「内側」に置く。
    /// 同じビューに .sheet を2つ並べると、2枚目の提示が失敗して即座に閉じてしまう。
    @ViewBuilder
    private var reviewSheet: some View {
        if let sequence = model.recordedSequence {
            NavigationStack {
                SkeletonPlayer(sequence: sequence)
                    .navigationTitle("骨格を確認")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") { showingPlayer = false }
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button {
                                Task { await model.export() }
                            } label: {
                                Label("共有する", systemImage: "square.and.arrow.up")
                            }
                            .disabled(model.isExporting)
                        }
                    }
                    .overlay {
                        if model.isExporting {
                            ExportingOverlay()
                        }
                    }
                    .sheet(item: $model.exportURL) { url in
                        ShareSheet(items: [url])
                    }
            }
        }
    }

    // MARK: - 上部：ガイドと計測値

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRecording {
                RecordingBadge(secondsLeft: model.recordingSecondsLeft)
            }

            if let message = model.guidanceMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .padding(10)
                    .background(.orange.opacity(0.9), in: Capsule())
            }

            ForEach(model.liveMeasurements, id: \.0) { label, measurement in
                HStack {
                    Text(label)
                    Spacer()
                    Text(measurement.map { String(format: "%.0f°", $0.degrees) } ?? "—")
                        .monospacedDigit()
                }
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 280, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 下部：収録ボタンとカメラ切り替え

    private var bottomBar: some View {
        HStack {
            Spacer()

            Button {
                model.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: model.isRecording ? 6 : 30)
                        .fill(.red)
                        .frame(
                            width: model.isRecording ? 30 : 60,
                            height: model.isRecording ? 30 : 60
                        )
                }
                .animation(.snappy, value: model.isRecording)
            }
            .accessibilityLabel(model.isRecording ? "収録を止める" : "5秒間収録する")

            Spacer()
        }
        .overlay(alignment: .trailing) {
            Button {
                model.toggleCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .disabled(model.isRecording)
            .accessibilityLabel(model.isFrontCamera ? "背面カメラに切り替える" : "前面カメラに切り替える")
        }
        .overlay(alignment: .leading) {
            // 2つ並べて置く。overlay を2つ重ねて別々に .leading / .bottomLeading を
            // 指定すると、このバー自体の高さが小さいため実質同じ位置に重なる。
            HStack(spacing: 12) {
                Button {
                    showingLibrary = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .disabled(model.isRecording)
                .accessibilityLabel("保存した記録")
                .sheet(isPresented: $showingLibrary) {
                    SkeletonLibraryView()
                        .onAppear { model.suspend(.library) }
                        .onDisappear { model.resume(.library) }
                }

                Button {
                    showingVideoAnalysis = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .disabled(model.isRecording)
                .accessibilityLabel("動画から骨格をつくる")
                // このシートはボタン自身に付ける。ContentView 本体に .sheet を
                // 2つ並べると、2枚目の提示が失敗して即座に閉じてしまう。
                .sheet(isPresented: $showingVideoAnalysis) {
                    VideoAnalysisView()
                        .onAppear { model.suspend(.videoAnalysisSheet) }
                        .onDisappear { model.resume(.videoAnalysisSheet) }
                }
            }
        }
    }
}

// MARK: - カウントダウンの数字

private struct CountdownNumber: View {
    let seconds: Int

    var body: some View {
        Text("\(seconds)")
            .font(.system(size: 220, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 16)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: seconds)
            .allowsHitTesting(false)
            .accessibilityLabel("開始まで \(seconds) 秒")
    }
}

// MARK: - 収録中の表示

/// 画面の縁を赤く点滅させる。離れた位置からでも収録中だと分かるようにする。
private struct RecordingBorder: View {
    @State private var dim = false

    var body: some View {
        Rectangle()
            .strokeBorder(.red, lineWidth: 18)
            .ignoresSafeArea()
            .opacity(dim ? 0.35 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .onDisappear { dim = false }
    }
}

/// 残り秒数を大きく出す。
private struct RecordingBadge: View {
    let secondsLeft: Int?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
            Text("REC")
                .font(.title3.bold())
            if let secondsLeft {
                Text("\(secondsLeft)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: secondsLeft)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.red, in: Capsule())
        .accessibilityLabel("収録中。残り \(secondsLeft ?? 0) 秒")
    }
}

// MARK: - 収録動画の解析中

private struct AnalyzingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("高フレームレート映像を解析しています…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - 書き出し中

private struct ExportingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("書き出しています…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }
}

// MARK: - 共有シート

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// URL を sheet(item:) で使うための最小の Identifiable 適合。
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
