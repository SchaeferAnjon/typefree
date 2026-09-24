import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - Microphone picker sheet

final class MicrophonePickerSheet: NSObject, NSWindowDelegate {
    private let theme: VPTheme
    private var sheet: NSWindow?
    private var listStack: NSStackView?
    private var meterView: VUMeterView?
    private var meterEngine: AVAudioEngine?
    private var meterAudioUnit: AudioUnit?
    private var meterFormat: AVAudioFormat?
    private var meterDeviceID: AudioDeviceID?
    private var onClose: (() -> Void)?

    init(theme: VPTheme) {
        self.theme = theme
        super.init()
    }

    func present(over host: NSWindow, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "麦克风"
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        sheet.delegate = self
        self.sheet = sheet

        let cv = KeyAwareView()
        cv.onEscape = { [weak self] in self?.dismiss() }
        cv.wantsLayer = true
        cv.layer?.setAppearanceBackground(theme.bg)
        sheet.contentView = cv

        let title = NSTextField(labelWithString: "麦克风")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = theme.text
        let sub = NSTextField(wrappingLabelWithString: "选择能捕捉到你声音的麦克风。如果指示条没有跳动，请试试别的。")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = theme.text2
        sub.maximumNumberOfLines = 0

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)
        self.listStack = listStack

        let doneBtn = VPButton(title: "完成", style: .primary, size: .regular,
                               theme: theme, target: self, action: #selector(doneTapped))
        doneBtn.keyEquivalent = "\r"
        doneBtn.translatesAutoresizingMaskIntoConstraints = false

        title.translatesAutoresizingMaskIntoConstraints = false
        sub.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(title)
        cv.addSubview(sub)
        cv.addSubview(scroll)
        cv.addSubview(doneBtn)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: cv.topAnchor, constant: 18),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: doneBtn.topAnchor, constant: -16),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            doneBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            doneBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -18),
        ])

        rebuildList()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onListOrSelChanged),
            name: .voicePolishMicrophoneListDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onListOrSelChanged),
            name: .voicePolishMicrophoneSelectionDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingWillStart),
            name: .voicePolishRecordingWillStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingDidStop),
            name: .voicePolishRecordingDidStop,
            object: nil
        )

        host.beginSheet(sheet) { [weak self] _ in
            self?.teardown()
        }

        // Defer meter start so sheet animates in smoothly first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startMeterForCurrentSelection()
        }
    }

    @objc private func onListOrSelChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildList()
            self?.startMeterForCurrentSelection()
        }
    }

    @objc private func recordingWillStart() {
        stopMeter()
    }

    /// 录音让出的麦克风还回来：面板还开着就把电平表接着跑，不然录完一句话电平条就一直不动
    @objc private func recordingDidStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sheet != nil else { return }
            self.startMeterForCurrentSelection()
        }
    }

    private func rebuildList() {
        guard let listStack else { return }
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let mgr = MicrophoneManager.shared
        let followingName = mgr.systemDefaultDeviceName ?? "未知"
        listStack.addArrangedSubview(makeRow(
            uid: MicrophoneManager.systemDefaultUID,
            primary: "跟随系统默认（\(followingName)）",
            // 选的设备拔掉了，勾暂时落在这一行：写明原因，插回来会自动切回去
            secondary: mgr.isPreferredDeviceMissing ? "所选麦克风未连接，暂用这个；插回来会自动切回去" : "随系统输入设置切换",
            isSelected: mgr.selectedUID == MicrophoneManager.systemDefaultUID,
            isRecommended: false
        ))

        for device in mgr.devices {
            listStack.addArrangedSubview(makeRow(
                uid: device.uid,
                primary: device.name,
                secondary: device.isBuiltIn ? "Mac 内置麦克风" : "外部麦克风",
                isSelected: mgr.selectedUID == device.uid,
                isRecommended: device.isBuiltIn
            ))
        }
        for v in listStack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeRow(uid: String, primary: String, secondary: String, isSelected: Bool, isRecommended: Bool) -> NSView {
        let row = MicrophoneRowView(uid: uid)
        row.onClick = { [weak self] selectedUID in
            MicrophoneManager.shared.select(uid: selectedUID)
            self?.rebuildList()
            self?.startMeterForCurrentSelection()
        }
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.borderWidth = isSelected ? 2 : 1
        row.layer?.setAppearanceBorder((isSelected ? theme.accent : theme.sep))
        row.layer?.setAppearanceBackground((isSelected ? theme.accentSoft : theme.card))

        let p = NSTextField(labelWithString: primary)
        p.font = .systemFont(ofSize: 14, weight: .medium)
        p.textColor = theme.text
        p.lineBreakMode = .byTruncatingTail

        let s = NSTextField(labelWithString: secondary)
        s.font = .systemFont(ofSize: 11)
        s.textColor = theme.text3

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(p)
        textStack.addArrangedSubview(s)

        let recommended: NSView
        if isRecommended {
            let pill = NSTextField(labelWithString: "推荐")
            pill.font = .systemFont(ofSize: 10, weight: .semibold)
            pill.textColor = theme.accent
            pill.backgroundColor = theme.accentSoft
            pill.drawsBackground = true
            pill.isBezeled = false
            pill.isEditable = false
            pill.alignment = .center
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 4
            pill.layer?.masksToBounds = true
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.widthAnchor.constraint(equalToConstant: 36).isActive = true
            pill.heightAnchor.constraint(equalToConstant: 18).isActive = true
            recommended = pill
        } else {
            recommended = NSView()
        }

        let meterContainer = NSView()
        meterContainer.translatesAutoresizingMaskIntoConstraints = false
        meterContainer.widthAnchor.constraint(equalToConstant: 70).isActive = true
        meterContainer.heightAnchor.constraint(equalToConstant: 18).isActive = true
        if isSelected {
            let meter = VUMeterView()
            meter.tint = theme.accent
            meter.translatesAutoresizingMaskIntoConstraints = false
            meterContainer.addSubview(meter)
            NSLayoutConstraint.activate([
                meter.leadingAnchor.constraint(equalTo: meterContainer.leadingAnchor),
                meter.trailingAnchor.constraint(equalTo: meterContainer.trailingAnchor),
                meter.topAnchor.constraint(equalTo: meterContainer.topAnchor),
                meter.bottomAnchor.constraint(equalTo: meterContainer.bottomAnchor),
            ])
            self.meterView = meter
        }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(textStack)
        stack.addArrangedSubview(NSView())
        if isRecommended { stack.addArrangedSubview(recommended) }
        stack.addArrangedSubview(meterContainer)
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        row.identifier = NSUserInterfaceItemIdentifier(uid)
        return row
    }

    @objc private func rowTapped(_ gesture: NSClickGestureRecognizer) {
        guard let v = gesture.view, let uid = v.identifier?.rawValue else { return }
        MicrophoneManager.shared.select(uid: uid)
    }

    // MARK: VU meter

    private func startMeterForCurrentSelection() {
        stopMeter()
        let manager = MicrophoneManager.shared
        guard let deviceID = manager.resolvedDeviceID else { return }
        meterDeviceID = deviceID

        if manager.selectedUID != MicrophoneManager.systemDefaultUID {
            startAUHALMeter(deviceID: deviceID)
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let chan = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<count {
                let v = abs(chan[0][i])
                if v > peak { peak = v }
            }
            DispatchQueue.main.async { self.meterView?.update(level: peak) }
        }
        do {
            engine.prepare()
            try engine.start()
            meterEngine = engine
        } catch {
            NSLog("[MicrophonePicker] meter engine failed: %@", error.localizedDescription)
        }
    }

    private func startAUHALMeter(deviceID: AudioDeviceID) {
        var mutableDeviceID = deviceID
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            NSLog("[MicrophonePicker] HALOutput component not found")
            return
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            NSLog("[MicrophonePicker] AudioComponentInstanceNew failed: %d", Int(status))
            return
        }

        func fail(_ operation: String, _ status: OSStatus) {
            NSLog("[MicrophonePicker] %@ failed: %d", operation, Int(status))
            AudioComponentInstanceDispose(unit)
            meterFormat = nil
        }

        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { fail("Enable AUHAL input", status); return }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { fail("Disable AUHAL output", status); return }

        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { fail("Set AUHAL input device", status); return }

        let sampleRate = nominalSampleRate(for: deviceID) ?? 48_000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fail("Create AUHAL meter format", -1)
            return
        }
        meterFormat = format
        var streamDescription = format.streamDescription.pointee
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { fail("Set AUHAL stream format", status); return }

        var callback = AURenderCallbackStruct(
            inputProc: MicrophonePickerSheet.auhalMeterCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { fail("Set AUHAL meter callback", status); return }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { fail("AudioUnitInitialize", status); return }

        meterAudioUnit = unit
        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            fail("AudioOutputUnitStart", status)
            meterAudioUnit = nil
            return
        }
    }

    private static let auhalMeterCallback: AURenderCallback = { refCon, flags, timestamp, _, frameCount, _ in
        let picker = Unmanaged<MicrophonePickerSheet>.fromOpaque(refCon).takeUnretainedValue()
        return picker.renderAUHALMeter(flags: flags, timestamp: timestamp, frameCount: frameCount)
    }

    private func renderAUHALMeter(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit = meterAudioUnit else { return noErr }

        let byteCount = Int(frameCount) * MemoryLayout<Float>.size
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
        defer { data.deallocate() }

        let audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteCount),
            mData: data
        )
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, &bufferList)
        guard status == noErr else { return status }

        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)
        var rms: Float = 0
        var peak: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            rms += sample * sample
            let v = Swift.abs(sample)
            if v > peak { peak = v }
        }
        rms = sqrt(rms / max(Float(count), 1))
        let level = min(max(peak * 3.0, rms * 12.0), 1.0)
        DispatchQueue.main.async { [weak self] in
            self?.meterView?.update(level: level)
        }
        return noErr
    }

    private func stopMeter() {
        if let e = meterEngine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        meterEngine = nil
        if let unit = meterAudioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        meterAudioUnit = nil
        meterFormat = nil
        meterDeviceID = nil
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    @objc private func doneTapped() {
        dismiss()
    }

    private func dismiss() {
        guard let sheet, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }

    private func teardown() {
        stopMeter()
        NotificationCenter.default.removeObserver(self)
        onClose?()
        onClose = nil
        sheet?.delegate = nil
        sheet = nil
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
    }
}
