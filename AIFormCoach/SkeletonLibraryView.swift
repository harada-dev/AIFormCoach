import SwiftUI

/// 保存した骨格の一覧。お気に入りと直近の記録を分けて表示する。
struct SkeletonLibraryView: View {

    @ObservedObject private var library = SkeletonLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var labelTarget: SkeletonLibrary.Entry?
    @State private var labelText = ""
    @State private var errorMessage: String?
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            List {
                favoritesSection
                recentsSection
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
            .alert("エラー", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("一言メモ", isPresented: .constant(labelTarget != nil)) {
                TextField("例：自分のベスト／コーチのお手本", text: $labelText)
                Button("保存") { commitLabel() }
                Button("キャンセル", role: .cancel) { labelTarget = nil }
            } message: {
                Text("あとで見つけやすいように名前を付けられます。")
            }
            .sheet(item: $shareURL) { url in
                ShareSheet(items: [url])
            }
        }
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
        } footer: {
            if !library.recents.isEmpty {
                Text("\(SkeletonLibrary.maxRecents)本を超えると古いものから消えます。残したいものはお気に入りに登録してください。")
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
                        diagnosisDestination(for: sequence)
                    } label: {
                        Label("診断を見る", systemImage: "stethoscope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
        .alert("読み込めませんでした", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var metadata: some View {
        VStack(spacing: 0) {
            metaRow("出自", entry.source.displayName)
            Divider()
            metaRow("フレーム数", "\(entry.frameCount)")
            Divider()
            metaRow("フレームレート", String(format: "%.0f fps", entry.fps))
            Divider()
            metaRow("長さ", String(format: "%.2f 秒", Double(entry.durationMs) / 1000))
            Divider()
            metaRow("角度定義", "v\(entry.angleDefinitionVersion)")
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

    @ViewBuilder
    private func diagnosisDestination(for sequence: PoseSequence) -> some View {
        let outcome = Result { try DiagnosisEngine.diagnose(sequence, side: kickingSide) }

        switch outcome {
        case .success(let diagnosis):
            DiagnosisView(diagnosis: diagnosis, sequence: sequence)
        case .failure(let error):
            ContentUnavailableView(
                "診断できませんでした",
                systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription)
            )
        }
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
