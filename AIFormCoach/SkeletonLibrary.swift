import Foundation
import SwiftUI
import Combine

/// 撮影した骨格の保存庫。
///
/// **なぜ必要か**
/// これまで `.fsc` は一時ディレクトリ（`temporaryDirectory`）に書いていました。
/// あれは共有シートに渡すための場所で、iOS がいつ削除しても仕様通りです。
/// 後から見返す機能としては成立しないため、アプリ専用のドキュメント領域へ移します。
///
/// **保存方針**
/// - 直近 20 本を自動保存。超えたら古いものから削除
/// - お気に入りは最大 5 件。**直近20本の枠から溢れても削除されない**
/// - お気に入りには一言メモを付けられる（「自分のベスト」「コーチのお手本」など）
/// - 出自（自分で撮った / 受け取った）を記録する。他人の骨格と自分の記録が
///   混ざると、比較の基準として意味を失うため
@MainActor
final class SkeletonLibrary: ObservableObject {

    static let shared = SkeletonLibrary()

    static let maxRecents = 20
    static let maxFavorites = 5

    @Published private(set) var entries: [Entry] = []

    /// 撮影日時の新しい順。お気に入りを除いた通常の記録。
    var recents: [Entry] {
        entries.filter { !$0.isFavorite }.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// お気に入り。追加した順。
    var favorites: [Entry] {
        entries.filter(\.isFavorite).sorted { $0.favoritedAt ?? .distantPast < $1.favoritedAt ?? .distantPast }
    }

    var canAddFavorite: Bool { favorites.count < Self.maxFavorites }

    // MARK: - 記録の型

    enum Source: String, Codable, Sendable {
        /// アプリで自分が撮影した
        case recorded
        /// AirDrop や LINE で受け取った（他人の骨格の可能性がある）
        case imported

        var displayName: String {
            switch self {
            case .recorded: return "自分の記録"
            case .imported: return "受け取った記録"
            }
        }

        var symbolName: String {
            switch self {
            case .recorded: return "figure.kickboxing"
            case .imported: return "square.and.arrow.down"
            }
        }
    }

    struct Entry: Identifiable, Codable, Sendable, Equatable {
        let id: UUID
        /// 保存ディレクトリ内のファイル名。
        var filename: String
        var recordedAt: Date
        var savedAt: Date
        var source: Source

        var isFavorite: Bool
        var favoritedAt: Date?
        /// お気に入りの一言メモ。
        var label: String?

        // 一覧表示用の要約。毎回ファイルを展開しなくて済むよう保存時に計算する。
        var engine: String
        var angleDefinitionVersion: Int
        var frameCount: Int
        var fps: Double
        var durationMs: Int
        /// バックスイング最深の膝屈曲角（0° = 完全伸展）。計測できなければ nil。
        var kneeFlexion: Double?

        var displayTitle: String {
            if let label, !label.isEmpty { return label }
            return Self.formatter.string(from: recordedAt)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M月d日 HH:mm"
            return f
        }()
    }

    enum LibraryError: LocalizedError {
        case favoritesFull
        case fileMissing
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .favoritesFull:
                return "お気に入りは\(SkeletonLibrary.maxFavorites)件までです。どれかを解除してから追加してください。"
            case .fileMissing:
                return "ファイルが見つかりません。削除された可能性があります。"
            case .saveFailed(let message):
                return "保存に失敗しました：\(message)"
            }
        }
    }

    // MARK: - 保存場所

    private let directory: URL
    private let indexURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Skeletons", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func fileURL(for entry: Entry) -> URL {
        directory.appendingPathComponent(entry.filename)
    }

    // MARK: - 保存

    /// 骨格を保存し、直近20本を超えた分（お気に入りを除く）を削除する。
    @discardableResult
    func save(_ sequence: PoseSequence, source: Source = .recorded) throws -> Entry {
        let id = UUID()
        let filename = "\(id.uuidString).\(SkeletonDocument.fileExtension)"
        let url = directory.appendingPathComponent(filename)

        do {
            let data = try SkeletonDocument.encode(sequence)
            try data.write(to: url, options: .atomic)
        } catch {
            throw LibraryError.saveFailed(error.localizedDescription)
        }

        var knee: Double?
        if let index = JointAngles.deepestFlexionIndex(in: sequence, side: .right),
           let m = JointAngles.kneeFlexion(sequence.frames[index], side: .right) {
            knee = m.degrees
        }

        let entry = Entry(
            id: id,
            filename: filename,
            recordedAt: sequence.recordedAt,
            savedAt: .init(),
            source: source,
            isFavorite: false,
            favoritedAt: nil,
            label: nil,
            engine: sequence.engine,
            angleDefinitionVersion: JointAngles.definitionVersion,
            frameCount: sequence.frames.count,
            fps: sequence.averageFPS,
            durationMs: sequence.durationMs,
            kneeFlexion: knee
        )

        entries.append(entry)
        prune()
        persist()
        return entry
    }

    /// 直近の上限を超えた分を削除する。**お気に入りは対象外。**
    private func prune() {
        let excess = recents.count - Self.maxRecents
        guard excess > 0 else { return }

        // 古い順に削除
        let victims = recents.suffix(excess)
        for entry in victims {
            try? FileManager.default.removeItem(at: fileURL(for: entry))
            entries.removeAll { $0.id == entry.id }
        }
    }

    // MARK: - 読み込み

    func sequence(for entry: Entry) throws -> PoseSequence {
        let url = fileURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.fileMissing
        }
        return try SkeletonDocument.read(from: url)
    }

    // MARK: - お気に入り

    /// お気に入りに追加する。上限に達していれば失敗する。
    func addFavorite(_ entry: Entry, label: String) throws {
        guard canAddFavorite else { throw LibraryError.favoritesFull }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw LibraryError.fileMissing
        }
        entries[index].isFavorite = true
        entries[index].favoritedAt = .init()
        entries[index].label = label.isEmpty ? nil : label
        persist()
    }

    /// お気に入りを解除する。ファイル自体は残り、直近の枠に戻る。
    /// このとき上限を超えていれば古いものから削除される。
    func removeFavorite(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isFavorite = false
        entries[index].favoritedAt = nil
        entries[index].label = nil
        prune()
        persist()
    }

    func updateLabel(_ entry: Entry, label: String) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].label = label.isEmpty ? nil : label
        persist()
    }

    // MARK: - 削除

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: fileURL(for: entry))
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// PRD F9「ワンタップ削除」。保護者管理からの全削除に対応する。
    func deleteAll() {
        for entry in entries {
            try? FileManager.default.removeItem(at: fileURL(for: entry))
        }
        entries.removeAll()
        persist()
    }

    // MARK: - 共有

    /// 共有シートに渡すファイル。保存済みのものをそのまま使う。
    func shareURL(for entry: Entry) -> URL? {
        let url = fileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 索引の入出力

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([Entry].self, from: data) else { return }

        // 実ファイルが無くなっている項目は索引から落とす。
        entries = loaded.filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
        }
        if entries.count != loaded.count { persist() }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
