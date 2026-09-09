import Foundation
import DeviceCore
#if os(macOS)
import IOKit
#endif

/// The `host` row of a run record — the machine running the tool, exactly
/// one per record, written by the runner (`unit-identity.md`, "What the
/// bench writes"). `id` stays nil until a local registry exists.
public enum HostUnit {
    public static func current() -> PhysicalUnit {
        var claims: [String: String] = [:]
        #if os(macOS)
        claims["apple.model"] = sysctlString("hw.model")
        let expert = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if expert != 0 {
            defer { IOObjectRelease(expert) }
            claims["apple.serial"] = registryString(expert, kIOPlatformSerialNumberKey)
            claims["apple.platform_uuid"] = registryString(expert, kIOPlatformUUIDKey)
        }
        #else
        claims["apple.model"] = sysctlString("hw.machine")
        #endif
        return PhysicalUnit(role: .host, claims: claims)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    #if os(macOS)
    private static func registryString(_ entry: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
    #endif
}
