import CoreAudio

/// The system's current default microphone and speakers.
///
/// Audio engines kept ready between uses (so the microphone opens fast) are
/// tied to the devices they were built on. Comparing a snapshot taken at build
/// time with the current one tells whether the user has switched devices since,
/// for example by connecting AirPods, and the engine needs rebuilding.
struct DefaultAudioDevices: Equatable, Sendable {
    let input: AudioDeviceID
    let output: AudioDeviceID

    static func current() -> DefaultAudioDevices {
        DefaultAudioDevices(
            input: device(kAudioHardwarePropertyDefaultInputDevice),
            output: device(kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    private static func device(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : 0
    }
}
