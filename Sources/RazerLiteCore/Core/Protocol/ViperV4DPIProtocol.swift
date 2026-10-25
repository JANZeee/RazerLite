import Foundation

/// Exact-model 04/06 encoding reviewed from OpenMouse @ 54c68c69… .
/// Storage byte 1 is intentional: do not describe this operation as temporary.
enum ViperV4DPIProtocol {
    static func validateTarget(x: Int, y: Int) throws {
        guard (100...50000).contains(x), (100...50000).contains(y), x % 50 == 0, y % 50 == 0 else {
            throw MouseQueryError.malformed("目标 DPI 必须在 100–50000 之间，且为 50 的整数倍")
        }
    }

    static func writableBaseline(_ payload: [UInt8]) throws -> MouseDPIState {
        let state = try ViperV4ReadProtocol.dpiState(payload)
        // Public capture in OpenRazer #2760 confirms GET indices are 1-based, SET indices 0-based.
        // Refuse other layouts that would lose unknown per-stage metadata when re-encoded.
        for index in state.stages.indices {
            let offset = 3 + index * 7
            guard payload[offset] == UInt8(index + 1), payload[offset + 5] == 0, payload[offset + 6] == 0 else {
                let layout = state.stages.indices.map { i in
                    let o = 3 + i * 7
                    return "\(payload[o]):\(payload[o + 5])/\(payload[o + 6])"
                }.joined(separator: ", ")
                throw MouseQueryError.malformed("档位索引或保留字段未适配（\(layout)）；保持只读")
            }
        }
        return state
    }

    static func replacingCurrent(in baseline: MouseDPIState, x: Int, y: Int) throws -> MouseDPIState {
        try validateTarget(x: x, y: y)
        var stages = baseline.stages
        stages[baseline.activeStage - 1] = MouseDPIStage(x: x, y: y)
        return MouseDPIState(activeStage: baseline.activeStage, stages: stages)
    }

    static func request(_ state: MouseDPIState) -> [UInt8] {
        var frame = ViperV4ReadProtocol.request(.dpiStages)
        frame[5] = UInt8(3 + state.stages.count * 7)
        frame[7] = 0x06
        frame[8] = 1
        frame[9] = UInt8(state.activeStage)
        frame[10] = UInt8(state.stages.count)
        for (index, stage) in state.stages.enumerated() {
            let offset = 11 + index * 7
            frame[offset] = UInt8(index)
            frame[offset + 1] = UInt8(stage.x >> 8)
            frame[offset + 2] = UInt8(stage.x & 0xFF)
            frame[offset + 3] = UInt8(stage.y >> 8)
            frame[offset + 4] = UInt8(stage.y & 0xFF)
        }
        frame[88] = ViperV4ReadProtocol.checksum(frame)
        return frame
    }
}
