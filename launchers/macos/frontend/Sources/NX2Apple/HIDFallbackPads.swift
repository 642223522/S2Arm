// S2Arm（不是上游文件）：面板列出 HID 兜底手柄（#1151）。GameController 认不出的 Switch 样式 HID 手柄（授权第三方「… Pro Controller」、
//   macOS 27 上的原厂一代 Pro），游戏里由宿主 macos/hid_pad.m 按 HID 元素直读、有输入；启动器原先只看 GameController，面板里没有它们。
//   这里只看「接没接上」（共享打开、不读输入报告，同 Gen1HIDWatcher），认法与宿主 s2a_hid_pad_wants 同一条：名字带「Pro Controller」；
//   GameController 已认出的同名手柄由宿主让位，这里同样不重复列（listed）。
import Foundation
import IOKit.hid

final class HIDFallbackPads {
    private var manager: IOHIDManager?
    private var present: [IOHIDDevice] = []
    private var onNames: (([String]) -> Void)?

    /// 面板要列的兜底手柄名（纯函数，单测）：HID 设备名里带「Pro Controller」的（大小写不敏感，同宿主），
    ///   去掉 GameController 已列出的同名手柄（同一只不列两次）；同名的几只各算一只
    static func listed(hid: [String], system: [String]) -> [String] {
        let known = Set(system.map { $0.lowercased() })
        return hid.filter { $0.range(of: "Pro Controller", options: .caseInsensitive) != nil && !known.contains($0.lowercased()) }
    }

    /// 一直看接上的 HID 手柄（启动器开着就开）；接上 / 断开就报一次现在的全部设备名
    func observe(_ handler: @escaping ([String]) -> Void) {
        onNames = handler
        guard manager == nil else { publish(); return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map { [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as [String: Any] }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            guard let context else { return }
            let watcher = Unmanaged<HIDFallbackPads>.fromOpaque(context).takeUnretainedValue()
            if !watcher.present.contains(where: { $0 === device }) { watcher.present.append(device); watcher.publish() }
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let watcher = Unmanaged<HIDFallbackPads>.fromOpaque(context).takeUnretainedValue()
            watcher.present.removeAll { $0 === device }; watcher.publish()
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }
    private func publish() {
        onNames?(present.compactMap { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String })
    }
    deinit {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
