import Cocoa
import ApplicationServices

class TextDelivery {
    enum DeliveryResult: Equatable {
        case pasted
        case copiedOnlyNeedsAccessibility
    }

    var debugLog: ((String) -> Void)?

    private static let chatAppNames: Set<String> = [
        "微信",
        "wechat",
        "企业微信",
        "wecom",
        "telegram",
        "telegram desktop",
        "qq",
        "messages",
        "信息",
        "whatsapp",
        "discord",
        "slack",
        "飞书",
        "lark",
        "钉钉",
        "dingtalk",
        "line",
        "signal",
        "messenger"
    ]

    private static let sentenceEndingPunctuation: Set<Character> = [
        "。", "！", "？", "…", ".", "!", "?", "\n",
        "，", ",", "；", ";", "：", ":", "》", "）", ")", "」", "】"
    ]

    static func adjustedTextForDelivery(_ text: String, frontmostAppName: String?) -> String {
        guard shouldRemoveTrailingFullStop(for: frontmostAppName),
              let fullStopRange = text.range(of: "。", options: .backwards) else {
            return text
        }

        let suffixAfterFullStop = text[fullStopRange.upperBound...]
        guard suffixAfterFullStop.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return text
        }

        var adjusted = text
        adjusted.removeSubrange(fullStopRange)
        return adjusted
    }

    private static func shouldRemoveTrailingFullStop(for appName: String?) -> Bool {
        guard let appName else { return false }
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chatAppNames.contains(normalized)
    }

    func hasAccessibilityPermission(promptIfNeeded: Bool = false) -> Bool {
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }

        return AXIsProcessTrusted()
    }

    func deliver(text: String) -> DeliveryResult {
        let finalText = text

        // 1. Copy to clipboard —— 先快照用户原有剪贴板内容，贴完后还原，避免“占用剪贴板”。
        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(finalText, forType: .string)
        let changeCountAfterSet = pasteboard.changeCount
        debugLog?("TextDelivery: pasteboard set chars=\(finalText.count)")

        // 2. Auto-paste only when Accessibility permission is available.
        guard hasAccessibilityPermission(promptIfNeeded: true) else {
            // 没有辅助功能权限时不会自动粘贴，需保留我们的文本供用户手动 ⌘V，故不还原。
            debugLog?("TextDelivery: accessibility missing, copied only")
            return .copiedOnlyNeedsAccessibility
        }

        debugLog?("TextDelivery: scheduling paste in 30ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.simulatePaste()
            self.debugLog?("TextDelivery: simulatePaste posted")
            // 等粘贴被目标 App 读取后再还原用户原剪贴板。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.restorePasteboard(pasteboard, items: savedItems, expectedChangeCount: changeCountAfterSet)
            }
        }

        return .pasted
    }

    /// 快照当前剪贴板的全部条目（文字/图片/文件等所有类型），用独立副本保存以便稍后写回。
    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// 还原用户原剪贴板内容。若期间用户又复制了新东西（changeCount 变化），则放弃还原，保留用户的新内容。
    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [NSPasteboardItem], expectedChangeCount: Int) {
        guard pasteboard.changeCount == expectedChangeCount else {
            debugLog?("TextDelivery: clipboard changed by user, skip restore")
            return
        }
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        debugLog?("TextDelivery: clipboard restored items=\(items.count)")
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 通过辅助功能 API 读取当前聚焦输入框的文字内容
    private func readFocusedTextFieldValue() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func simulatePaste() {
        // Create ⌘V key event
        let vKeyCode: CGKeyCode = 9  // 'v' key

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
