// S2Arm（不是上游文件）：按设备看一代 Joy-Con（#520 D2）。macOS 把两只一代 Joy-Con 合成一个手柄，GameController 分不出是哪一只、
//   也分不出是第几套，所以这里另开 IOHID（共享打开，不抢 GameController）：
//   · 一直看哪几只连着（设备 id = 序列号即蓝牙地址；宿主 joycon_imu.m s2a_joycon_device_id 同一套），给分配玩家对「谁还在」；
//   · 分配中读每只的输入报告认手势：标准全报告 0x30（左只按键在第 3 字节 SL 0x20 / SR 0x10 / L 0x40，右只在第 1 字节同位）、
//     简单报告 0x3F（第 1 字节 SL 0x10 / SR 0x20，第 2 字节肩键 0x40）。
//   位照公开协议（dekuNukem Nintendo_Switch_Reverse_Engineering；宿主同一份 runtime/src/pad.c s2a_joycon1_decode）。同按那一刻报一次
import Foundation
import IOKit.hid

final class Gen1HIDWatcher {
    private var manager: IOHIDManager?
    private var onGesture: ((String, Int, Int) -> Void)?
    private var onDevices: (([PlayerAssignment.Gen1Device]) -> Void)?
    private var held: [String: Int] = [:]   // 设备 id → 上一笔的手势（只在变成新手势时报）
    private var onPress: ((String, String?) -> Void)?   // 认手柄：有新按下的键（设备 id、按的哪个键）
    private var heldButtons: [String: UInt64] = [:]
    private var present: [IOHIDDevice] = []
    private var reading = false

    /// 解析一笔报告的手势（纯函数，单测）：2 = SL + SR 同按、3 = 肩键（左只 L / 右只 R）、0 = 没有
    static func gesture(pid: Int, report: [UInt8]) -> Int {
        guard let first = report.first else { return 0 }
        let off = first == 0x30 || first == 0x3f ? 1 : 0
        let full = off == 1 ? first == 0x30 : report.count >= 48
        var sl = false, sr = false, shoulder = false
        if full {
            guard report.count >= off + 5 else { return 0 }
            let b = report[off + 2 + (pid == 0x2006 ? 2 : 0)]
            sl = b & 0x20 != 0; sr = b & 0x10 != 0; shoulder = b & 0x40 != 0
        } else {
            guard report.count >= off + 2 else { return 0 }
            sl = report[off] & 0x10 != 0; sr = report[off] & 0x20 != 0; shoulder = report[off + 1] & 0x40 != 0
        }
        return sl && sr ? 2 : shoulder ? 3 : 0
    }

    /// 一笔报告里按着的键（纯函数）。位：全报告 0x30 第 3–5 字节放 0–23 位（右只键 / 共用键 / 左只键）；
    ///   简单报告 0x3F 第 1–2 字节放 24–39 位——两种报告分开放，keyName 才分得出。
    ///   摇杆方向放 40–43 位（上 / 下 / 左 / 右）：全报告读第 6–11 字节的 12 位摇杆值（偏中心 700 以上算推），简单报告读第 3 字节的 8 方向（8 = 没推）。
    ///   方向照 Joy-Con 自己竖着拿的朝向，不转横握
    static func buttons(report: [UInt8]) -> UInt64 {
        guard let first = report.first else { return 0 }
        let off = first == 0x30 || first == 0x3f ? 1 : 0
        let up: UInt64 = 1 << 40, down: UInt64 = 1 << 41, left: UInt64 = 1 << 42, right: UInt64 = 1 << 43
        if off == 1 ? first == 0x30 : report.count >= 48 {
            guard report.count >= off + 5 else { return 0 }
            var bits = UInt64(report[off + 2]) | UInt64(report[off + 3]) << 8 | UInt64(report[off + 4]) << 16
            for base in [off + 5, off + 8] where report.count >= base + 3 {
                let x = Int(report[base]) | Int(report[base + 1] & 0x0f) << 8, y = Int(report[base + 1] >> 4) | Int(report[base + 2]) << 4
                guard x != 0 || y != 0 else { continue }   // 这只没有这根摇杆
                if y - 2048 > 700 { bits |= up }; if 2048 - y > 700 { bits |= down }
                if 2048 - x > 700 { bits |= left }; if x - 2048 > 700 { bits |= right }
            }
            return bits
        }
        guard report.count >= off + 2 else { return 0 }
        var bits = UInt64(report[off]) << 24 | UInt64(report[off + 1]) << 32
        if report.count > off + 2 {
            // 8 方向：0 上、1 右上、2 右、3 右下、4 下、5 左下、6 左、7 左上；8 = 没推
            switch report[off + 2] {
            case 0: bits |= up
            case 1: bits |= up | right
            case 2: bits |= right
            case 3: bits |= down | right
            case 4: bits |= down
            case 5: bits |= down | left
            case 6: bits |= left
            case 7: bits |= up | left
            default: break
            }
        }
        return bits
    }
    /// 一下新按下的键里第一个 → 显示的字（纯函数）；side 0 左只、1 右只（简单报告同一位左右只意思不同）
    static func keyName(_ pressed: UInt64, side: Int) -> String? {
        let (u, d, l, r) = (NS2LauncherController.keyUp, NS2LauncherController.keyDown, NS2LauncherController.keyLeft, NS2LauncherController.keyRight)
        let full = ["Y", "X", "B", "A", "SR", "SL", "R", "ZR", "−", "+", "RS", "LS", "Home", "Capture", "", "", d, u, r, l, "SR", "SL", "L", "ZL"]
        let simple1 = side == 0 ? [l, d, u, r, "SL", "SR", "", ""] : ["A", "X", "B", "Y", "SL", "SR", "", ""]   // 第 1 字节只用到 6 位
        let simple2 = ["−", "+", "LS", "RS", "Home", "Capture", side == 0 ? "L" : "R", side == 0 ? "ZL" : "ZR"]
        let stick = [u, d, l, r]
        for bit in 0..<44 where pressed & (1 << UInt64(bit)) != 0 {
            let name: String? = bit < 24 ? full[bit] : bit < 32 ? simple1[bit - 24] : bit < 40 ? simple2[bit - 32] : stick[bit - 40]
            if let name, !name.isEmpty { return name }
        }
        return nil
    }

    /// 设备 id（纯函数，单测）：序列号优先，没有用 LocationID（loc-十六进制）——宿主 s2a_joycon_device_id 同一套，两边认同一只
    static func deviceID(serial: String?, location: UInt32?) -> String? {
        if let serial, !serial.isEmpty { return serial }
        if let location { return "loc-" + String(location, radix: 16) }
        return nil
    }
    private static func deviceID(_ device: IOHIDDevice) -> String? {
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
        return deviceID(serial: serial, location: location)
    }
    private static func side(_ device: IOHIDDevice) -> Int {
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
        return pid == 0x2006 ? 0 : pid == 0x2007 ? 1 : -1
    }

    /// 一直看哪几只连着（启动器开着就开）；连上 / 断开就报一次现在的全部
    func observe(_ handler: @escaping ([PlayerAssignment.Gen1Device]) -> Void) {
        onDevices = handler
        ensureManager()
        publish()
    }
    /// 分配中认手势：(设备 id, 0 左只 / 1 右只, 手势)；nil 停
    func watchGestures(_ handler: ((String, Int, Int) -> Void)?) {
        onGesture = handler; held = [:]
        updateReading()
    }
    /// 认手柄：有新按下的键就报（设备 id）；nil 停。打开那一刻已按着的键不算（第一笔只记下来）
    func watchPresses(_ handler: ((String, String?) -> Void)?) {
        onPress = handler; heldButtons = [:]
        updateReading()
    }
    /// 手势或按键有人要看就读输入报告，都不要就停
    private func updateReading() {
        ensureManager()
        let wanted = onGesture != nil || onPress != nil
        guard let m = manager, wanted != reading else { return }
        reading = wanted
        if reading {
            IOHIDManagerRegisterInputReportCallback(m, { context, _, sender, _, _, report, length in
                guard let context, let sender else { return }
                let watcher = Unmanaged<Gen1HIDWatcher>.fromOpaque(context).takeUnretainedValue()
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                watcher.handle(device: device, report: Array(UnsafeBufferPointer(start: report, count: length)))
            }, Unmanaged.passUnretained(self).toOpaque())
        } else {
            IOHIDManagerRegisterInputReportCallback(m, nil, nil)
        }
    }

    private func ensureManager() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [0x2006, 0x2007].map { [kIOHIDVendorIDKey: 0x057e, kIOHIDProductIDKey: $0] as [String: Any] }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            guard let context else { return }
            let watcher = Unmanaged<Gen1HIDWatcher>.fromOpaque(context).takeUnretainedValue()
            if !watcher.present.contains(where: { $0 === device }) { watcher.present.append(device); watcher.publish() }
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let watcher = Unmanaged<Gen1HIDWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.present.removeAll { $0 === device }; watcher.publish()
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }
    private func publish() {
        onDevices?(present.compactMap { d in
            let side = Self.side(d)
            guard side >= 0, let id = Self.deviceID(d) else { return nil }
            return PlayerAssignment.Gen1Device(id: id, side: side)
        })
    }
    private func handle(device: IOHIDDevice, report: [UInt8]) {
        let side = Self.side(device)
        guard side >= 0, let id = Self.deviceID(device) else { return }
        let g = Self.gesture(pid: side == 0 ? 0x2006 : 0x2007, report: report)
        if g != held[id] { held[id] = g; if g != 0 { onGesture?(id, side, g) } }
        if let onPress {
            let now = Self.buttons(report: report)
            if let before = heldButtons[id], now & ~before != 0 { onPress(id, Self.keyName(now & ~before, side: side)) }
            heldButtons[id] = now
        }
    }
    deinit {
        guard let m = manager else { return }
        IOHIDManagerRegisterInputReportCallback(m, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
