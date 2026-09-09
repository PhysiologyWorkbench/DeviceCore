import Foundation

/// What one vendor kit contributes to the bench: its tools under its glossary
/// noun — the shape `VendorRadio` proved, DeviceCore owning the frame and each
/// kit filling one (`PolarBench`, `LovenseBench`, …; the generic wire
/// primitives fill the `wire` catalogue here in BenchKit).
public struct BenchCatalogue: Sendable {
    /// The noun the tools group under in `pwb bench list`: `wire`, `polar`,
    /// `lovense`.
    public let noun: String
    public let tools: [any BenchTool]
    /// Whether these tools drive the radio, and so cannot run while the app
    /// holds it (bench-host-toolbox.md "Radio contention"). A catalogue over
    /// some other transport — the host's audio endpoints, a serial rig —
    /// says no and is not gated by a live control channel.
    public let claimsRadio: Bool

    public init(noun: String, tools: [any BenchTool], claimsRadio: Bool = false) {
        self.noun = noun
        self.tools = tools
        self.claimsRadio = claimsRadio
    }
}

/// Every registered tool across the catalogues the front-end imports, checked
/// for name collisions once at startup, dispatched by name.
public struct BenchToolRegistry: Sendable {
    public let catalogues: [BenchCatalogue]
    /// All tools, name-sorted — `pwb bench list` order.
    public let tools: [any BenchTool]

    public init(catalogues: [BenchCatalogue]) throws {
        self.catalogues = catalogues
        var seen: Set<String> = []
        for tool in catalogues.flatMap(\.tools) {
            guard seen.insert(tool.name).inserted else {
                throw BenchToolError.duplicateToolName(tool.name)
            }
        }
        tools = catalogues.flatMap(\.tools).sorted { $0.name < $1.name }
    }

    public func tool(named name: String) -> (any BenchTool)? {
        tools.first { $0.name == name }
    }

    /// The catalogue a tool came from — what a front-end asks before applying
    /// a rule that belongs to one kind of tool rather than to all of them.
    public func catalogue(containing name: String) -> BenchCatalogue? {
        catalogues.first { $0.tools.contains { $0.name == name } }
    }
}
