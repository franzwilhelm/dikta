import AVFoundation
import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    // Shown in the recording panel so it is obvious which microphone is listening.
    var symbol: String {
        if transport == kAudioDeviceTransportTypeBuiltIn { return "laptopcomputer" }
        if isBluetooth {
            return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        }
        return "mic"
    }

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioDevices {
    static let preferenceKey = "microphoneUID"
    // Bluetooth microphones start slowly and lose the first words, so everyone
    // defaults to the Mac's own microphone. "" follows the macOS input choice.
    static let builtIn = "builtin"

    private static let lastSymbolKey = "lastMicrophoneSymbol"
    static var lastSymbol: String {
        get { UserDefaults.standard.string(forKey: lastSymbolKey) ?? "laptopcomputer" }
        set { UserDefaults.standard.set(newValue, forKey: lastSymbolKey) }
    }

    // The previous recording's microphone, when it started instantly (not Bluetooth).
    private static let lastQuickKey = "lastQuickMicrophoneUID"
    static var lastQuickUID: String? {
        get { UserDefaults.standard.string(forKey: lastQuickKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastQuickKey) }
    }

    static var choice: String { UserDefaults.standard.string(forKey: preferenceKey) ?? builtIn }

    // The chosen microphone when connected; nil means use the macOS input.
    static func chosen(from inputs: [InputDevice]) -> InputDevice? {
        let choice = choice
        if choice == builtIn { return inputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn } }
        if choice.isEmpty { return nil }
        return inputs.first { $0.uid == choice }
    }

    static var inputs: [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter(hasInput).compactMap(device)
    }

    static var systemDefault: InputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return device(id)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func device(_ id: AudioDeviceID) -> InputDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return InputDevice(id: id, uid: uid, name: name, transport: transport)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
