import Foundation

/// PRD F11：骨格ファイルの書き出し / 読み込み。
/// Phase 0 の「LINE や AirDrop で友だちの骨格を送り合う」検証の中核。
///
/// 形式 v2 から 3D 座標（worldLandmarks）を含みます。v1 のファイルも読めます。
///
/// 実測値（5 秒 / 30fps / 151 フレーム）:
/// - v1（2Dのみ）: 圧縮前 128KB → 圧縮後 41KB
/// - v2（2D+3D）: 圧縮前 約 220KB → 圧縮後 約 70KB
///
/// 注意：Apple の `.zlib` は名前に反して **zlib ヘッダのない生の DEFLATE** を出します。
/// 他のプラットフォームやサーバー側で読む場合は「ヘッダなし DEFLATE」
/// （Python なら `zlib.decompressobj(-15)`）として扱ってください。
enum SkeletonDocument {

    static let fileExtension = "fsc"
    static let formatIdentifier = "fsc-skeleton"
    static let formatVersion = 2

    // MARK: - ファイル表現

    private struct Payload: Codable {
        var format: String
        var version: Int
        /// どのエンジンで推定したか。エンジン差し替え時の互換性判断に使う。
        var engine: String
        /// 角度定義のバージョン。JointAngles.definitionVersion と対応。
        var angleDefinitionVersion: Int
        var jointCount: Int
        var recordedAt: Date
        var frames: [Frame]

        struct Frame: Codable {
            /// 収録開始からの経過ミリ秒。必ず先頭が 0 になるよう正規化して書き出す。
            var t: Int
            /// [x, y, z, visibility] × 33 の平坦な配列（画像正規化座標）。
            var k: [Float]
            /// [x, y, z] × 33 の平坦な配列（メートル 3D 座標）。v1 には存在しない。
            var w: [Float]?
        }
    }

    // MARK: - 書き出し

    static func encode(_ sequence: PoseSequence) throws -> Data {
        // タイムスタンプはアプリ起動からの経過時間が入っているため、
        // 先頭を 0 に揃える。複数ファイルを並べて比較するときに扱いやすくなる。
        let origin = sequence.frames.first?.timestampMs ?? 0

        let frames = sequence.frames.map { frame -> Payload.Frame in
            var flat = [Float]()
            flat.reserveCapacity(frame.keypoints.count * 4)
            for kp in frame.keypoints {
                flat.append(round4(kp.x))
                flat.append(round4(kp.y))
                flat.append(round4(kp.z))
                flat.append(round2(kp.visibility))
            }

            var world: [Float]?
            if frame.hasWorld {
                var w = [Float]()
                w.reserveCapacity(frame.world.count * 3)
                for p in frame.world {
                    // メートル単位なので 4 桁で 0.1mm。十分な精度。
                    w.append(round4(p.x))
                    w.append(round4(p.y))
                    w.append(round4(p.z))
                }
                world = w
            }

            return Payload.Frame(t: frame.timestampMs - origin, k: flat, w: world)
        }

        let payload = Payload(
            format: formatIdentifier,
            version: formatVersion,
            engine: sequence.engine,
            angleDefinitionVersion: JointAngles.definitionVersion,
            jointCount: PoseJoint.allCases.count,
            recordedAt: sequence.recordedAt,
            frames: frames
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(payload)
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    /// 共有シートに渡せる一時ファイルを作る。
    static func write(_ sequence: PoseSequence, name: String? = nil) throws -> URL {
        let data = try encode(sequence)
        let stamp = ISO8601DateFormatter().string(from: sequence.recordedAt)
            .replacingOccurrences(of: ":", with: "-")
        let filename = (name ?? "skeleton_\(stamp)") + "." + fileExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 読み込み

    static func decode(_ data: Data) throws -> PoseSequence {
        // 圧縮なしの手書きファイルも受け付ける。
        let json: Data
        if let inflated = try? (data as NSData).decompressed(using: .zlib) as Data {
            json = inflated
        } else {
            json = data
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: json)

        guard payload.format == formatIdentifier else {
            throw DocumentError.unrecognizedFormat
        }
        guard payload.version <= formatVersion else {
            throw DocumentError.newerVersion(payload.version)
        }
        guard payload.jointCount == PoseJoint.allCases.count else {
            throw DocumentError.jointCountMismatch(payload.jointCount)
        }

        let count = payload.jointCount

        let frames: [PoseFrame] = payload.frames.map { f in
            var keypoints = [Keypoint]()
            keypoints.reserveCapacity(count)
            for i in stride(from: 0, to: min(f.k.count, count * 4), by: 4) {
                keypoints.append(
                    Keypoint(x: f.k[i], y: f.k[i + 1], z: f.k[i + 2], visibility: f.k[i + 3])
                )
            }

            var world = [WorldPoint]()
            if let w = f.w, w.count >= count * 3 {
                world.reserveCapacity(count)
                for i in stride(from: 0, to: count * 3, by: 3) {
                    world.append(WorldPoint(x: w[i], y: w[i + 1], z: w[i + 2]))
                }
            }

            return PoseFrame(timestampMs: f.t, keypoints: keypoints, world: world)
        }

        return PoseSequence(frames: frames, engine: payload.engine, recordedAt: payload.recordedAt)
    }

    static func read(from url: URL) throws -> PoseSequence {
        try decode(try Data(contentsOf: url))
    }

    // MARK: -

    enum DocumentError: LocalizedError {
        case unrecognizedFormat
        case newerVersion(Int)
        case jointCountMismatch(Int)

        var errorDescription: String? {
            switch self {
            case .unrecognizedFormat:
                return "このファイルは骨格データではありません。"
            case .newerVersion(let v):
                return "新しい形式（v\(v)）のファイルです。アプリを更新してください。"
            case .jointCountMismatch(let count):
                return "関節数が一致しません（\(count)点）。別の骨格エンジンで作られたファイルです。"
            }
        }
    }

    private static func round4(_ value: Float) -> Float { (value * 10_000).rounded() / 10_000 }
    private static func round2(_ value: Float) -> Float { (value * 100).rounded() / 100 }
}
