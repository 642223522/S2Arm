// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import NXLauncher

/// Native alerts and file panels keep AppKit's actions and key equivalents.
/// Add controller glyphs to those same buttons, without replacing the panel.
@MainActor final class LauncherPadNativeButtons {
    private struct Hint {
        weak var button: NSButton?
        let image: NSImage?
        let position: NSControl.ImagePosition
    }
    private var hints: [ObjectIdentifier: Hint] = [:]
    private weak var lastWindow: NSWindow?
    private var lastSymbols: [PadShortcut: String] = [:]

    func buttons(in window: NSWindow) -> [(PadShortcut, NSButton)] {
        func collect(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        guard let content = window.contentView else { return [] }
        let all = collect(content).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.title.isEmpty && $0.frame.width > 30 }
        guard let primary = all.first(where: { $0.keyEquivalent == "\r" || $0.cell === window.defaultButtonCell }) else { return [] }
        var result: [(PadShortcut, NSButton)] = [(.rightTrigger, primary)]
        if let cancel = all.first(where: { $0.keyEquivalent == "\u{1b}" }) { result.append((.back, cancel)) }
        let baseline = primary.convert(primary.bounds, to: content).midY
        let secondary = all.filter { candidate in
            !result.contains { $0.1 === candidate } && abs(candidate.convert(candidate.bounds, to: content).midY - baseline) < 24
        }.sorted { $0.frame.minX < $1.frame.minX }
        for (shortcut, button) in zip([PadShortcut.secondary, .tertiary], secondary) { result.append((shortcut, button)) }
        return result
    }
    func update(in window: NSWindow, presentation: PadPresentation) {
        guard presentation.connected else { restore(); return }
        guard lastWindow !== window || lastSymbols != presentation.symbols else { return }
        lastWindow = window; lastSymbols = presentation.symbols
        hints = hints.filter { $0.value.button != nil }
        for (shortcut, button) in buttons(in: window) {
            let key = ObjectIdentifier(button)
            if hints[key] == nil { hints[key] = Hint(button: button, image: button.image, position: button.imagePosition) }
            let symbol = presentation.symbols[shortcut.displayed] ?? shortcut.displayed.symbol   // 确认键一律显示 A（单只 Joy-Con 没有 ZR）
            if button.image?.name() != symbol {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                image?.setName(symbol)
                button.image = image
                button.imagePosition = .imageLeading
            }
        }
    }
    func restore() {
        for hint in hints.values {
            hint.button?.image = hint.image; hint.button?.imagePosition = hint.position
        }
        hints.removeAll()
        lastWindow = nil; lastSymbols = [:]
    }
}
