import Foundation

/// Evidence from this process only. A version, protocol revision or slash-command
/// catalogue cannot prove that an optional RPC command is available.
struct OMPCapabilities: Equatable, Sendable {
    enum Support: String, Codable, Sendable { case unknown, supported, unsupported }
    enum MessageUpdates: String, Sendable { case full, delta }
    private(set) var commands: [String: Support] = [:]
    private(set) var protocolVersion = 1
    private(set) var messageUpdates = MessageUpdates.full
    /// A recognized native policy rejection is separate from command support.
    /// A successful get cannot prove that creation has been enabled again.
    private(set) var goalIsDisabled = false

    subscript(_ command: String) -> Support { commands[command] ?? .unknown }

    /// Set only after this process replies to the GUI extension's private
    /// handshake. Its public SDK queue controls run in the same native session.
    mutating func confirmQueueBridge() {
        commands["gui_remove_follow_up"] = .supported
    }

    mutating func observe(_ response: JSONValue) {
        guard response["type"]?.string == "response", let command = response["command"]?.string else { return }
        if response["success"]?.bool == true {
            if ["set_fast_mode", "set_slow_mode"].contains(command) {
                guard response["data"]?["enabled"]?.bool != nil else { return }
            }
            if command == "goal", OMPGoalReply(response["data"] ?? .null) == nil { return }
            if command == "set_cache_warming" {
                guard response["data"]?["mode"]?.string.flatMap(OMPCacheWarmingMode.init(rawValue:)) != nil else { return }
            }
            commands[command] = .supported
            if command == "negotiate_protocol", let version = response["data"]?["protocolVersion"]?.int {
                protocolVersion = version
            }
            if command == "set_event_filter" {
                // Older OMP accepts this command but ignores messageUpdates.
                // Only the echoed projection proves delta mode is active.
                let projection = response["data"]?["messageUpdates"]?.string
                messageUpdates = projection.flatMap(MessageUpdates.init(rawValue:)) ?? .full
            }
        } else if response["success"]?.bool == false {
            let error = response["error"]?.string
            if command == "goal", error == "Goal mode is disabled (goal.enabled)." { goalIsDisabled = true }
            if error == "Unknown command: \(command)" || error == "Unknown command" {
                commands[command] = .unsupported
            } else if ["cancel_subagent", "steer_subagent"].contains(command),
                      OMPSubagentCapabilities.recognizesControl(response) {
                commands[command] = .supported
            }
            // Other failures (including an unavailable registry) prove nothing.
        }
    }
}
