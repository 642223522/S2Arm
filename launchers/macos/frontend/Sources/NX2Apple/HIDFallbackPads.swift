// S2Arm（不是上游文件）：面板列出 HID 兜底手柄（#1151）。GameController 认不出的 HID 手柄（授权第三方「… Pro Controller」、
//   macOS 27 上的原厂一代 Pro、谷歌 Stadia 蓝牙 / 八位堂 D-input 等通用手柄），游戏里由宿主 macos/hid_pad.m 按 HID 元素直读、有输入；
//   启动器原先只看 GameController，面板里没有它们。这里只看「接没接上」（共享打开、不读输入报告，同 Gen1HIDWatcher），
//   认法同宿主（macos/hid_generic.h）：名字带「Pro Controller」的都列；别的通用手柄除了微软 / 索尼 / 任天堂（系统原生认得，交给 GameController）都列；
//   GameController 已认出的同名手柄由宿主让位，这里同样不重复列（listed）
import Foundation
import IOKit.hid

final class HIDFallbackPads {
    private var manager: IOHIDManager?
    private var present: [IOHIDDevice] = []
    private var onNames: (([String]) -> Void)?

    /// 名字带「Pro Controller」（大小写不敏感，同宿主 s2a_hidg_is_pro）：宿主走 Switch Pro 协议那一支，面板按 Pro 样式手柄画
    static func isPro(_ name: String) -> Bool { name.range(of: "Pro Controller", options: .caseInsensitive) != nil }
    /// 宿主会不会按 HID 读这只（纯函数，单测；同宿主 hid_pad.m attach）：Pro 那一支都读；通用手柄里微软 / 索尼 / 任天堂的交给 GameController
    static func hostReads(name: String, vendor: Int) -> Bool { isPro(name) || ![0x045e, 0x054c, 0x057e].contains(vendor) }
    /// 面板要列的兜底手柄名（纯函数，单测）：宿主会读的 HID 设备名（observe 已按 hostReads 筛过），
    ///   去掉 GameController 已列出的同名手柄（同一只不列两次，大小写不敏感）；同名的几只各算一只
    static func listed(hid: [String], system: [String]) -> [String] {
        let known = Set(system.map { $0.lowercased() })
        return hid.filter { !known.contains($0.lowercased()) }
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
        onNames?(present.compactMap { device in
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            return Self.hostReads(name: name, vendor: vendor) ? name : nil
        })
    }
    deinit {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
