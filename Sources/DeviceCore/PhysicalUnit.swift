import Foundation

/// One physical unit as a record names it — the shape ruled in PWB
/// `design/unit-identity.md` (R55), shared by the bench run record and the
/// device registry. Identity, what the device asserted, and how this host
/// reached it are kept apart: `id` is an opaque registry-minted `urn:uuid:`
/// or absent; `claims` carry typed keys (`ble.name`, `dis.serial`,
/// `apple.model`, vendor prefixes); `bindings` are host-relative by
/// definition (`cb.peripheral`, `tty`). The wire supplies evidence, never
/// the key.
public struct PhysicalUnit: Codable, Equatable, Sendable {
    public var id: String?
    public var role: Role
    /// The part of a multi-function unit under test: `speaker`, `motor2`.
    public var component: String?
    /// A human note when nothing else identifies the unit.
    public var label: String?
    public var claims: [String: String]
    public var bindings: [String: String]

    /// What part the unit played in the run that names it.
    public enum Role: String, Codable, Sendable {
        /// The thing measured.
        case dut
        /// A device whose readings the dut is compared against.
        case reference
        /// A device the signal passes through.
        case path
        /// The machine running the tool — exactly one per record, written
        /// by the runner, never by a tool.
        case host
    }

    public init(id: String? = nil, role: Role, component: String? = nil,
                label: String? = nil, claims: [String: String] = [:],
                bindings: [String: String] = [:]) {
        self.id = id
        self.role = role
        self.component = component
        self.label = label
        self.claims = claims
        self.bindings = bindings
    }
}
