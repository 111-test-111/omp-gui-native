import Foundation
@testable import OMPGUI

@main
struct NativeApprovalChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(root.path.contains("/build.noindex/verification/runs/"))
        let fixtures = JSONValue.parse(try Data(contentsOf: root.appendingPathComponent("approval-requests.json")))!.array!
        var responses: [JSONValue] = []
        for fixture in fixtures {
            let frame = fixture["frame"]!
            let dialog = OMPExtensionDialog.request(frame)!
            guard let approval = OMPExtensionDialog.approval(for: dialog, frame: frame) else {
                fatalError("Installed OMP approval was projected as an ordinary question: \(fixture)")
            }
            precondition(approval.instanceID == dialog.instanceID && approval.deadline == dialog.deadline)
            precondition(approval.decisions.count == 2 && approval.options.count == 2)
            var result: [String: JSONValue] = ["name": fixture["name"]!, "options": frame["options"]!]
            for option in approval.decisions {
                let response = OMPExtensionDialog.response(to: dialog,
                    answers: [dialog.id: QuestionAnswer(selectedOptions: [option.id])])
                precondition(response["confirmed"] == nil && response["cancelled"] == nil)
                result[option.role == .decline ? "deny" : "allow"] = response
            }
            responses.append(.object(result))
        }
        try JSONValue.array(responses).data(pretty: true).write(to: root.appendingPathComponent("approval-responses.json"))
        print("PASS native approval projection: \(fixtures.count) installed request shapes and their production responses")
    }
}
