import Testing
@testable import CareThread

struct MoreQuickActionsTests {
    @Test("加号面板先完整展示四种资料来源且拍照入口不受设备影响")
    func sourceActionsAreCompleteAndFirst() {
        #expect(
            MoreQuickAction.sourceActions
                == [.camera, .photos, .files, .manual]
        )
        #expect(MoreQuickAction.sourceActions.first == .camera)
        #expect(MoreQuickAction.camera.title == "拍照扫描")
    }

    @Test("提醒、日历、导出、对比和迁移归入第二组")
    func toolActionsStaySeparate() {
        #expect(
            MoreQuickAction.toolActions
                == [
                    .medication, .followUp, .calendar,
                    .export, .compare, .transfer
                ]
        )
    }
}
