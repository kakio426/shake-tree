import Carbon.HIToolbox
import AppKit

/// Carbon RegisterEventHotKey 기반 전역 단축키.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    /// 기본: ⇧⌘V
    init(keyCode: UInt32 = UInt32(kVK_ANSI_V),
         modifiers: UInt32 = UInt32(cmdKey | shiftKey),
         action: @escaping () -> Void)
    {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon 이벤트 디스패처는 메인 스레드에서 호출된다
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x514B_4B41) /* 'QKKA' */, id: 1)
        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }
}

/// 접근성 권한이 있으면 앞 앱에 ⌘V 키 이벤트를 보내 붙여넣는다.
@MainActor
enum Paster {
    static var canPaste: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        // kAXTrustedCheckOptionPrompt 전역 var는 Swift 6 동시성 검사에 걸려 리터럴로 대체
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func pasteToFrontmostApp() {
        guard canPaste, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
