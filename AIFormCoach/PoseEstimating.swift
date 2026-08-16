import Foundation
import CoreMedia

/// 骨格推定エンジンの抽象。
///
/// この protocol より上のレイヤー（角度計算、フェーズ分割、基準値突合、描画）は
/// MediaPipe の型を一切知りません。エンジンを差し替えても上位ロジックは無変更で動きます。
///
/// Vision framework 実装を追加する場合は `VisionPoseEstimator` を作り、
/// 足部の 4 点（heel / footIndex）を visibility 0 で埋めてください。
/// 足部を使う指標はそこで自動的に「計測不能」として扱われます。
protocol PoseEstimating: AnyObject {
    /// `PoseSequence.engine` に記録される識別子。バージョンまで含めること。
    var engineID: String { get }

    /// 推定結果の受け取り先。
    var onFrame: ((PoseFrame) -> Void)? { get set }

    /// カメラからのフレームを投入する。処理中のフレームがある場合は破棄される。
    func submit(sampleBuffer: CMSampleBuffer, timestampMs: Int)
}
