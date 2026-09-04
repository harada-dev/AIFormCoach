import SwiftUI

/// お手本を選んで比較を開始する画面。
/// お手本の候補はお気に入り(自分のベスト / 友だち・コーチの記録)から選ぶ。
struct ComparisonStarterView: View {

    /// 比較する自分の記録。
    let mine: PoseSequence
    let mineSide: JointAngles.Side
    let mineLabel: String

    @ObservedObject private var library = SkeletonLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if library.favorites.isEmpty {
                    Section {
                        Text("お気に入りに登録した記録がありません。友だちやコーチから受け取った `.fsc` を開いてお気に入りに登録すると、お手本として使えます。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(library.favorites) { entry in
                            NavigationLink {
                                destination(for: entry)
                            } label: {
                                row(entry)
                            }
                        }
                    } header: {
                        Text("お手本を選ぶ")
                    } footer: {
                        Text("体格の差は脚の長さを揃えて打ち消すので、大人のお手本とも比べられます。")
                    }
                }
            }
            .navigationTitle("お手本とくらべる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .alert(
                "比較できません",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(_ entry: SkeletonLibrary.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.source.symbolName)
                .foregroundStyle(entry.source == .imported ? .blue : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    if let knee = entry.kneeFlexion {
                        Text("膝 \(Int(knee))°").monospacedDigit()
                    }
                    Text(entry.source.displayName)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func destination(for entry: SkeletonLibrary.Entry) -> some View {
        switch build(entry) {
        case .success(let result):
            ComparisonView(result: result)
        case .failure(let error):
            ScrollView {
                ContentUnavailableView {
                    Label("比較できません", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                }
            }
            .navigationTitle("お手本とくらべる")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func build(_ entry: SkeletonLibrary.Entry) -> Result<PoseComparison.Result, Error> {
        do {
            let model = try SkeletonLibrary.shared.sequence(for: entry)
            let result = try PoseComparison.compare(
                mine: mine,
                mineLabel: mineLabel,
                mineSide: mineSide,
                model: model,
                modelLabel: entry.displayTitle,
                // お手本の蹴り足は自分と同じと仮定する。
                // 左右が違う場合は向きの自動反転で概ね揃う。
                modelSide: mineSide
            )
            return .success(result)
        } catch {
            return .failure(error)
        }
    }
}
