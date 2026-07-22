/// Vendor-specific knobs for Lovense, isolated here so a second vendor can be
/// added without touching the generic `DeviceCatalog`: which config node to read
/// and the one firmware-dependent identifier rule. Everything else in the catalog
/// is generic Buttplug-config parsing.
enum Lovense {
    /// Key of the protocol node inside `buttplug-device-config-v4.json`.
    static let protocolKey = "lovense"

    /// Mirrors Buttplug's sole firmware-dependent identifier remap: a Flexer
    /// (`EI`) on firmware ≥3 is a distinct config row (`EI-FW3`). Everything else
    /// maps straight through.
    static func resolveIdentifier(_ code: String, firmware: Int?) -> String {
        (code == "EI" && (firmware ?? 0) >= 3) ? "EI-FW3" : code
    }
}
