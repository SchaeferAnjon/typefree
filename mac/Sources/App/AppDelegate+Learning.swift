import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    // MARK: - Manual Correction & Learning Feedback

    func showManualCorrection() {
        guard let lastText = lastDeliveredText, !lastText.isEmpty else {
            showError("没有可纠正的内容")
            return
        }

        let alert = NSAlert()
        alert.messageText = "纠正上次结果"
        let displayText = lastText.count > 80 ? String(lastText.prefix(80)) + "..." : lastText
        alert.informativeText = "Typefree 输出了：\n\(displayText)\n\n请在下方修改为正确的文字："
        alert.addButton(withTitle: "学习")
        alert.addButton(withTitle: "取消")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 396, height: 80))
        textView.string = lastText
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let corrected = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != lastText else { return }

        let learner = HotWordsAutoLearner.shared
        learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
        let learned = learner.learnFromManualCorrection(original: lastText, corrected: corrected)
        if learned.isEmpty {
            showError("未检测到可学习的术语差异")
        } else {
            showLearningFeedback(learned)
        }
    }

    func showLearningFeedback(_ descriptions: [String]) {
        debugLog("Learned corrections: count=\(descriptions.count)")
        lastLearnedDescriptions = descriptions

        overlayWindow.onUndoLearn = { [weak self] in
            guard let self = self, !self.lastLearnedDescriptions.isEmpty else { return }
            let toUndo = self.lastLearnedDescriptions
            self.lastLearnedDescriptions = []
            let learner = HotWordsAutoLearner.shared
            learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
            learner.undoLearnedCorrections(toUndo)
            self.debugLog("User undid learned corrections: count=\(toUndo.count)")
        }

        let displayText = descriptions.joined(separator: "、")
        overlayWindow.show(state: .learned(description: displayText))
    }

    func showLearningSuggestion(_ descriptions: [String]) {
        debugLog("Learning suggestions: count=\(descriptions.count)")
        lastLearningSuggestionDescriptions = descriptions

        overlayWindow.onAcceptLearnSuggestion = { [weak self] in
            guard let self = self, !self.lastLearningSuggestionDescriptions.isEmpty else { return }
            let toLearn = self.lastLearningSuggestionDescriptions
            self.lastLearningSuggestionDescriptions = []

            let learner = HotWordsAutoLearner.shared
            learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
            let learned = learner.confirmPendingCorrections(toLearn)
            if learned.isEmpty {
                self.debugLog("Learning suggestions accepted but nothing new was added: count=\(toLearn.count)")
            } else {
                self.showLearningFeedback(learned)
            }
        }

        overlayWindow.onDismissLearnSuggestion = { [weak self] in
            self?.debugLog("Learning suggestions deferred: count=\(descriptions.count)")
            self?.lastLearningSuggestionDescriptions = []
        }

        let displayText = descriptions.joined(separator: "、")
        overlayWindow.show(state: .learnSuggestion(description: displayText))
    }
}
