//
//  PoseViewTransform.swift
//  AIFormCoach
//
//  重ね表示の視点切り替え(真横／斜め前／斜め後ろ)。
//  - 新規フレームワークなし(Foundation / simd のみ)
//  - 回転は描画にのみ作用する。角度算出・診断・承認判定には一切使わない
//  - 対象は「重ねる」モードのみ。「並べる」モードには適用しない(実装仕様§8/§10)
//
//  修正履歴:
//  - 目標ヨー角を固定値(+π/2)にしていたため、骨盤ヨーが -π/2 付近のクリップで
//    補正量が約180°になり、重ね表示だけ被写体が裏返る不具合を修正。
//    測定値に近いほうの ±π/2 を目標に選ぶ方式に変更した。
//  - 回転方向に蹴り足の符号を掛けていたのを廃止。前後の視点は cameraSide だけで
//    決まり、蹴り足とは無関係。あわせて斜めを前／後ろの2ケースに分けた。
//

import Foundation
import simd

// MARK: - 表示視点

enum PoseViewAngle: CaseIterable {
    case side           // 真横(0°)
    case obliqueFront   // 斜め45°(前から)
    case obliqueBack    // 斜め45°(後ろから)

    /// 回転量の大きさ
    var magnitude: Float {
        switch self {
        case .side:                       return 0
        case .obliqueFront, .obliqueBack: return .pi / 4
        }
    }

    /// 回す向き。前を +1、後ろを -1 とする。
    /// 実際の符号は cameraSide と obliqueBaseSign を掛けて決まる。
    var direction: Float {
        switch self {
        case .side:         return 0
        case .obliqueFront: return 1
        case .obliqueBack:  return -1
        }
    }

    var label: String {
        switch self {
        case .side:         return "真横"
        case .obliqueFront: return "斜め前"
        case .obliqueBack:  return "斜め後ろ"
        }
    }
}

// MARK: - 定数

enum PoseViewConfig {

    /// 斜め表示の基準符号。「斜め前」を選んで後ろから見える場合は反転する。
    /// 蹴り足には依存しない(前後は cameraSide だけで決まる)。
    static let obliqueBaseSign: Float = -1

    /// ψ 算出に使う基準フレーム前後の窓(片側フレーム数)
    static let yawWindowHalfWidth: Int = 5

    /// 正規化の補正量の上限(これを超えたら正規化しない)。
    /// 真横撮影で30°もずれることはない。超える場合は推定破綻か非真横撮影。
    static let maxNormalizationCorrection: Float = 30 * .pi / 180

    /// 奥行きによる線幅の倍率レンジ(奥 → 手前)
    static let depthWidthRange: ClosedRange<CGFloat> = 1.0...1.4
}

// MARK: - 向き正規化の結果

struct PoseOrientationResult {

    /// クリップ全体に適用するY軸回転量(撮影角度のずれのみを打ち消す小さな値)
    let correction: Float

    /// 撮影側。骨盤ヨーが正なら +1、負なら -1。
    /// 自分とお手本でこれが異なる場合、二人は反対側から撮られている。
    let cameraSide: Float

    /// 補正量が上限内に収まったか。false のとき correction は 0。
    let isReliable: Bool

    static let identity = PoseOrientationResult(correction: 0, cameraSide: 1, isReliable: false)
}

// MARK: - 向きの正規化

enum PoseOrientation {

    /// 1フレームの骨盤ヨー角(水平面 x-z 上での左腰→右腰の角度)
    static func yaw(of frame: [SIMD3<Float>]) -> Float? {
        guard frame.count > PoseJoint.rightHip.rawValue else { return nil }
        let hipL = frame[PoseJoint.leftHip.rawValue]
        let hipR = frame[PoseJoint.rightHip.rawValue]
        let dx = hipR.x - hipL.x
        let dz = hipR.z - hipL.z

        // 骨盤幅が極端に小さい=推定が壊れている可能性が高い
        guard (dx * dx + dz * dz).squareRoot() > 0.02 else { return nil }
        return atan2(dz, dx)
    }

    /// クリップ全体に適用する向き正規化(定数)を求める
    ///
    /// 基準フレーム1枚を中心とした窓の中央値を使う。
    /// **毎フレーム正規化してはいけない** — キック中の骨盤回旋は本物の運動情報であり、
    /// 毎フレーム揃えると消えてしまう。
    ///
    /// - Parameters:
    ///   - frames: 骨長正規化・腰中心済みの3D座標(クリップ全フレーム)
    ///   - referenceIndex: 時間整列に使っている基準点(ボール通過 or バックスイング最深)
    static func resolve(frames: [[SIMD3<Float>]],
                        referenceIndex: Int) -> PoseOrientationResult {

        guard let psi = medianYaw(frames: frames, referenceIndex: referenceIndex) else {
            return .identity
        }

        // 測定値に近いほうの ±π/2 を目標にする。
        // 固定値にすると撮影側によって約180°回してしまう。
        let side: Float = psi >= 0 ? 1 : -1
        let target = side * Float.pi / 2
        let correction = psi - target

        guard abs(correction) <= PoseViewConfig.maxNormalizationCorrection else {
            return PoseOrientationResult(correction: 0, cameraSide: side, isReliable: false)
        }
        return PoseOrientationResult(correction: correction, cameraSide: side, isReliable: true)
    }

    /// 基準フレーム周辺の ψ の中央値
    private static func medianYaw(frames: [[SIMD3<Float>]],
                                  referenceIndex: Int) -> Float? {
        guard !frames.isEmpty else { return nil }
        let ref = min(max(referenceIndex, 0), frames.count - 1)
        let lo = max(0, ref - PoseViewConfig.yawWindowHalfWidth)
        let hi = min(frames.count - 1, ref + PoseViewConfig.yawWindowHalfWidth)

        // 連続化の中心。基準フレームが壊れている場合は窓内の最初の有効値を使う
        var center: Float?
        if let y = yaw(of: frames[ref]) {
            center = y
        } else {
            for i in lo...hi where center == nil {
                center = yaw(of: frames[i])
            }
        }
        guard let anchor = center else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity(hi - lo + 1)
        for i in lo...hi {
            guard let y = yaw(of: frames[i]) else { continue }
            samples.append(unwrap(y, near: anchor))
        }
        guard !samples.isEmpty else { return nil }

        samples.sort()
        return samples[samples.count / 2]
    }

    /// angle を reference から ±π 以内に折り返す
    private static func unwrap(_ angle: Float, near reference: Float) -> Float {
        var a = angle
        while a - reference > .pi  { a -= 2 * .pi }
        while a - reference < -.pi { a += 2 * .pi }
        return a
    }
}

// MARK: - 視点変換

/// 向き正規化(クリップ定数)＋ 表示角度 を1つの回転にまとめたもの。
/// フレームごとの処理は行列適用1回で済む。
struct PoseViewTransform {

    private let theta: Float
    private let mirrorX: Bool

    /// - Parameters:
    ///   - orientation: `PoseOrientation.resolve` の戻り値
    ///   - viewAngle: 表示視点
    ///   - mirrorToMatch: 比較相手に合わせて左右反転するか
    ///
    /// 回転方向は蹴り足に依存しない。前後の視点は選手がカメラに対して
    /// どちらを向いているか(cameraSide)だけで決まる。
    init(orientation: PoseOrientationResult,
         viewAngle: PoseViewAngle,
         mirrorToMatch: Bool = false) {

        let sign = PoseViewConfig.obliqueBaseSign
                 * viewAngle.direction
                 * orientation.cameraSide

        self.theta = orientation.correction + viewAngle.magnitude * sign
        self.mirrorX = mirrorToMatch
    }

    /// 比較相手に合わせて左右反転すべきか
    ///
    /// 蹴り足が違う場合と、撮影側が違う場合の排他的論理和。
    /// 右足キックを左側から撮ると、右側から撮った左足キックと同じに見えるため。
    static func shouldMirror(selfKickFootIsRight: Bool,
                             otherKickFootIsRight: Bool,
                             selfOrientation: PoseOrientationResult,
                             otherOrientation: PoseOrientationResult) -> Bool {
        let footDiffers = selfKickFootIsRight != otherKickFootIsRight
        let sideDiffers = selfOrientation.cameraSide != otherOrientation.cameraSide
        return footDiffers != sideDiffers
    }

    /// 1点を変換する。投影は呼び出し側で (x, y) を使う。
    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = mirrorX ? SIMD3<Float>(-p.x, p.y, p.z) : p
        let c = cos(theta), s = sin(theta)
        return SIMD3<Float>(q.x * c + q.z * s,
                            q.y,
                            -q.x * s + q.z * c)
    }

    /// 1フレーム分をまとめて変換する
    func apply(frame: [SIMD3<Float>]) -> [SIMD3<Float>] {
        frame.map(apply)
    }
}

// MARK: - 奥行き表現

enum PoseDepthCue {

    /// 回転後の z から線幅の倍率を返す(手前を太く)
    static func widthScale(z: Float, in range: ClosedRange<Float>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 1e-5 else { return PoseViewConfig.depthWidthRange.lowerBound }

        // z が小さいほど手前(カメラ側)とする。逆なら実機で反転する。
        let t = CGFloat((range.upperBound - z) / span)
        let lo = PoseViewConfig.depthWidthRange.lowerBound
        let hi = PoseViewConfig.depthWidthRange.upperBound
        return lo + (hi - lo) * max(0, min(1, t))
    }

    /// フレーム内の z レンジ
    static func depthRange(ofZ zs: [Float]) -> ClosedRange<Float> {
        guard let lo = zs.min(), let hi = zs.max(), lo < hi else { return 0...1 }
        return lo...hi
    }
}
