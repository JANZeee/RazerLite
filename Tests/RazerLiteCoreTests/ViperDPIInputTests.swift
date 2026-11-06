import Testing
@testable import RazerLiteCore

struct ViperDPIInputTests {
    @Test func linkedEditingMirrorsEitherAxisIncludingIncompleteText() {
        var input = ViperDPIInput()
        #expect(input.axesLinked && input.target == nil && input.validationMessage() == nil)
        input.editX("1600")
        #expect(input.x == "1600" && input.y == "1600" && input.target == .init(x: 1600, y: 1600))
        input.editY("28x")
        #expect(input.x == "28x" && input.y == "28x" && input.target == nil)
        #expect(input.validationMessage() == "DPI 请输入整数。")
        input.editX("")
        #expect(input.x.isEmpty && input.y.isEmpty && input.target == nil)
    }

    @Test func explicitLinkAdoptsXAndUnlinkPreservesBothValues() {
        var input = ViperDPIInput(x: 800, y: 1600)
        #expect(!input.axesLinked)
        input.editY("2400")
        #expect(input.x == "800" && input.y == "2400")
        input.setLinked(true)
        #expect(input.x == "800" && input.y == "800")
        input.setLinked(false)
        #expect(input.x == "800" && input.y == "800")
        input.editX("1200")
        #expect(input.x == "1200" && input.y == "800")
    }

    @Test func loadedDeviceValuesRemainExactAndUnequalValuesStayUnlinked() {
        for original in [MouseDPIStage(x: 2846, y: 2846), .init(x: 6073, y: 49999), .init(x: 50, y: 50)] {
            let input = ViperDPIInput(x: original.x, y: original.y)
            #expect(input.x == String(original.x) && input.y == String(original.y))
            #expect(input.axesLinked == (original.x == original.y))
            #expect(input.matches(original))
            #expect(input.validationMessage(preserving: original) == nil)
            #expect(input.target == nil)
        }
    }

    @Test func invalidTargetsExplainTheProblemWithoutRoundingOrClamping() {
        for (text, message) in [("1.5", "DPI 请输入整数。"), ("99999999999999999999999999999", "DPI 请输入整数。"),
                                ("99", "DPI 须在 100–50,000 之间。"), ("50001", "DPI 须在 100–50,000 之间。"),
                                ("2846", "修改值须为 50 的整数倍。")] {
            var input = ViperDPIInput()
            input.editX(text)
            #expect(input.validationMessage() == message)
            #expect(input.target == nil && input.x == text && input.y == text)
        }
        var input = ViperDPIInput(x: 800, y: 1600)
        input.editY("")
        #expect(input.validationMessage() == "请填写 X 和 Y 轴 DPI。")
    }

    @Test func independentRowsProduceOneChangeListAndPreserveUntouchedFirmwareValues() throws {
        let baseline = MouseDPIState(activeStage: 3, stages: [
            .init(x: 400, y: 400), .init(x: 800, y: 800), .init(x: 2846, y: 2846),
            .init(x: 6073, y: 6073), .init(x: 49999, y: 49999)
        ])
        var rows = baseline.stages.map { ViperDPIInput(x: $0.x, y: $0.y) }
        rows[0].editX("600")
        rows[2].setLinked(false)
        rows[2].editX("2800")
        rows[2].editY("3200")
        let changes = try rows.indices.compactMap { index -> MouseDPIStageChange? in
            guard !rows[index].matches(baseline.stages[index]) else { return nil }
            let target = try #require(rows[index].target)
            return .init(stage: index + 1, x: target.x, y: target.y)
        }
        let after = try ViperV4DPIProtocol.replacingStages(in: baseline, changes: changes)
        #expect(changes.map(\.stage) == [1, 3])
        #expect(after.activeStage == 3 && after.stages.count == 5)
        #expect(after.stages[0] == .init(x: 600, y: 600))
        #expect(after.stages[2] == .init(x: 2800, y: 3200))
        #expect(after.stages[3] == baseline.stages[3] && after.stages[4] == baseline.stages[4])
    }
}
