import SwiftUI

/// 保存した骨格の一覧。お気に入りと直近の記録を分けて表示する。
///
/// **固まる不具合の修正について**
/// 旧実装は `.alert(isPresented: .constant(errorMessage != nil))` のように
/// `.constant` バインディングでアラートを提示していた。`.constant` は値を
/// 書き換えられないため、SwiftUI がアラートを閉じようとしても false にできず、
/// 見えないアラートが提示され続けて画面のタッチを吸収していた。
/// さらに同一ビューに `.alert` を2つ重ねており、シートの二重提示と同じ衝突も起きていた。
///
/// 対策:
/// - バインディングを get/set の両方を持つ形にし、閉じるときに状態を消す
/// - 2つのアラートを別のビュー階層に分けて付ける
struct SkeletonLibraryView: View {

    @ObservedObject private var library = SkeletonLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var labelTarget: SkeletonLibrary.Entry?
    @State private var isEditingLabel = false
    @State private var labelText = ""
    @State private var errorMessage: String?
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            List {
                favoritesSection
                recentsSection
            }
            // 一言メモの入力はリスト側に付ける（エラー用と別階層にする）
            .alert("一言メモ", isPresented: $isEditingLabel) {
                TextField("例：自分のベスト／コーチのお手本", text: $labelText)
                Button("保存") { commitLabel() }
                Button("キャンセル", role: .cancel) { labelTarget = nil }
            } message: {
                Text("あとで見つけやすいように名前を付けられます。")
            }
            .navigationTitle("保存した記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .overlay {
                if library.entries.isEmpty {
                    ContentUnavailableView(
                        "まだ記録がありません",
                        systemImage: "tray",
                        description: Text("撮影すると直近\(SkeletonLibrary.maxRecents)本まで自動で保存されます。")
                    )
                }
            }
            .sheet(item: $shareURL) { url in
                ShareSheet(items: [url])
            }
        }
        // エラーはナビゲーション側に付ける
        .alert("エラー", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 閉じたときに状態を消せるバインディング。`.constant` を使ってはならない。
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - お気に入り

    private var favoritesSection: some View {
        Section {
            ForEach(library.favorites) { entry in
                row(entry)
                    .swipeActions(edge: .trailing) {
                        Button("解除") { library.removeFavorite(entry) }
                            .tint(.orange)
                        Button("削除", role: .destructive) { library.delete(entry) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("名前") { beginLabelEdit(entry) }
                            .tint(.blue)
                    }
            }
        } header: {
            HStack {
                Label("お気に入り", systemImage: "star.fill")
                Spacer()
                Text("\(library.favorites.count) / \(SkeletonLibrary.maxFavorites)")
                    .monospacedDigit()
            }
        } footer: {
            if library.favorites.isEmpty {
                Text("自分のベストや、友だち・コーチから受け取ったお手本を登録しておくと、いつでも見返せます。上限\(SkeletonLibrary.maxFavorites)件。")
            }
        }
    }

    // MARK: - 直近

    private var recentsSection: some View {
        Section {
            ForEach(library.recents) { entry in
                row(entry)
                    .swipeActions(edge: .trailing) {
                        Button("削除", role: .destructive) { library.delete(entry) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("お気に入り") { beginLabelEdit(entry) }
                            .tint(.yellow)
                    }
            }
        } header: {
            HStack {
                Text("直近の記録")
                Spacer()
                Text("\(library.recents.count) / \(SkeletonLibrary.maxRecents)")
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 行

    private func row(_ entry: SkeletonLibrary.Entry) -> some View {
        NavigationLink {
            SkeletonDetailView(entry: entry, onShare: { shareURL = $0 })
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.source.symbolName)
                    .font(.title3)
                    .foregroundStyle(entry.source == .imported ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayTitle)
                        .font(.subheadline.weight(entry.isFavorite ? .semibold : .regular))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let knee = entry.kneeFlexion {
                            Text("膝 \(Int(knee))°")
                                .monospacedDigit()
                        }
                        Text("\(Int(entry.fps)) fps")
                            .monospacedDigit()
                        if entry.source == .imported {
                            Text(entry.source.displayName)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 一言メモ

    private func beginLabelEdit(_ entry: SkeletonLibrary.Entry) {
        if !entry.isFavorite, !library.canAddFavorite {
            errorMessage = SkeletonLibrary.LibraryError.favoritesFull.localizedDescription
            return
        }
        labelText = entry.label ?? ""
        labelTarget = entry
        isEditingLabel = true
    }

    private func commitLabel() {
        guard let target = labelTarget else { return }
        defer { labelTarget = nil }

        if target.isFavorite {
            library.updateLabel(target, label: labelText)
        } else {
            do {
                try library.addFavorite(target, label: labelText)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 詳細

/// 保存した骨格の再生と診断。
struct SkeletonDetailView: View {

    let entry: SkeletonLibrary.Entry
    let onShare: (URL) -> Void

    @State private var sequence: PoseSequence?
    @State private var kickingSide: JointAngles.Side = .right
    @State private var errorMessage: String?
    @State private var showingComparison = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let sequence {
                    metadata

                    Picker("蹴り足", selection: $kickingSide) {
                        Text("右足で蹴った").tag(JointAngles.Side.right)
                        Text("左足で蹴った").tag(JointAngles.Side.left)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    SkeletonPlayer(sequence: sequence)

                    NavigationLink {
                        DiagnosisDestination(sequence: sequence, side: kickingSide)
                    } label: {
                        Label("診断を見る", systemImage: "stethoscope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)

                    Button {
                        showingComparison = true
                    } label: {
                        Label("お手本とくらべる", systemImage: "person.2.wave.2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.horizontal)
                } else if errorMessage == nil {
                    ProgressView()
                        .padding(40)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(entry.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let url = SkeletonLibrary.shared.shareURL(for: entry) { onShare(url) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task { loadSequence() }
        .alert(
            "読み込めませんでした",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showingComparison) {
            if let sequence {
                ComparisonStarterView(mine: sequence, mineSide: kickingSide, mineLabel: "自分")
            }
        }
    }

    private var metadata: some View {
        VStack(spacing: 0) {
            metaRow("出自", entry.source.displayName)
            Divider()
            metaRow("フレームレート", String(format: "%.0f fps", entry.fps))
            Divider()
            metaRow("長さ", String(format: "%.2f 秒", Double(entry.durationMs) / 1000))
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func loadSequence() {
        guard sequence == nil else { return }
        do {
            sequence = try SkeletonLibrary.shared.sequence(for: entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 診断への遷移

/// 診断の実行と失敗表示をまとめたビュー。
/// 各画面で同じ処理を書かないよう、ここに集約する。
struct DiagnosisDestination: View {
    let sequence: PoseSequence
    let side: JointAngles.Side

    var body: some View {
        switch Result(catching: { try DiagnosisEngine.diagnose(sequence, side: side) }) {
        case .success(let diagnosis):
            DiagnosisView(diagnosis: diagnosis)
        case .failure(let error):
            ScrollView {
                ContentUnavailableView {
                    Label("うまく測れませんでした", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                        .multilineTextAlignment(.leading)
                }
            }
            .navigationTitle("今日の診断")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () throws -> Success) {
        do { self = .success(try body()) } catch { self = .failure(error) }
    }
}
