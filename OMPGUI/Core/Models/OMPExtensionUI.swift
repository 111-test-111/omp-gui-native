import Foundation

/// Bounded native presentation state. These values never execute extension logic.
struct OMPExtensionState: Equatable, Sendable {
    var statuses: [String: String] = [:]
    var widgets: [OMPExtensionWidget] = []

    mutating func observe(_ frame: JSONValue) -> Bool {
        switch frame["method"]?.string {
        case "setStatus":
            guard let key = frame["statusKey"]?.string else { return false }
            if let text = frame["statusText"]?.string {
                guard statuses[key] != nil || statuses.count < 16 else { return false }
                statuses[key] = Self.plainText(text, limit: 2_048)
            } else { statuses[key] = nil }
        case "setWidget":
            guard let key = frame["widgetKey"]?.string else { return false }
            let existing = widgets.firstIndex { $0.id == key }
            guard let lines = frame["widgetLines"]?.array else {
                if let existing { widgets.remove(at: existing) }
                return true
            }
            let widget = OMPExtensionWidget(id: key, lines: lines.prefix(64).compactMap(\.string).map { Self.plainText($0, limit: 2_048) },
                placement: frame["widgetPlacement"]?.string == "belowEditor" ? .belowEditor : .aboveEditor)
            if let existing { widgets[existing] = widget }
            else if widgets.count < 8 { widgets.append(widget) }
        default: return false
        }
        return true
    }

    /// TUI escape sequences and terminal control characters are presentation only.
    static func plainText(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
            .replacingOccurrences(of: "\\x1B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\x1B\\][^\\x07]*(?:\\x07|\\x1B\\\\)", with: "", options: .regularExpression)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
            .map(String.init).joined()
    }
}

struct OMPExtensionWidget: Identifiable, Equatable, Sendable {
    enum Placement: String, Sendable { case aboveEditor, belowEditor }
    var id: String
    var lines: [String]
    var placement: Placement
}

struct OMPLoginLink: Identifiable, Equatable, Sendable {
    var id: String
    var url: URL
    var launchURL: URL?
    var instructions: String?
    var destination: URL { launchURL ?? url }

    init?(_ frame: JSONValue) {
        guard let raw = frame["url"]?.string, let url = Self.webURL(raw) else { return nil }
        id = frame["id"]?.string ?? UUID().uuidString
        self.url = url
        // OMP's short URL is a local redirect. Do not accept another remote
        // domain as a substitute for the provider URL shown to the user.
        launchURL = frame["launchUrl"]?.string.flatMap(Self.webURL).flatMap { candidate in
            ["localhost", "127.0.0.1", "[::1]", "::1"].contains(candidate.host?.lowercased() ?? "") ? candidate : nil
        }
        instructions = frame["instructions"]?.string.map { OMPExtensionState.plainText($0, limit: 8_192) }
    }

    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// The exact native request is retained by OMPSession; this projection is display only.
enum OMPExtensionDialog {
    // The SDK adapter carries rich ask data through OMP's public input dialog.
    // Its native pending-request map still owns cancellation and response routing.
    static let askPrefix = "OMP_GUI_ASK_V1:"

    static func request(_ frame: JSONValue, now: Date = Date()) -> QuestionRequest? {
        guard let id = frame["id"]?.string, let method = frame["method"]?.string,
              ["select", "confirm", "input", "editor", "ask"].contains(method) else { return nil }
        let questions: [QuestionRequest.Question]
        var responseFormat: QuestionRequest.ResponseFormat = method == "confirm" ? .confirmation : .value
        var askQuestions = method == "ask" ? frame["questions"]?.array : nil
        if method == "input", let title = frame["title"]?.string, title.hasPrefix(askPrefix) {
            guard let data = String(title.dropFirst(askPrefix.count)).data(using: .utf8),
                  let payload = JSONValue.parse(data), payload["version"]?.int == 1,
                  let rows = payload["questions"]?.array else { return nil }
            askQuestions = rows
            responseFormat = .encodedAsk
        }
        if let askQuestions {
            var ids: Set<String> = []
            questions = askQuestions.compactMap { question in
                guard let qid = question["id"]?.string, !qid.isEmpty, ids.insert(qid).inserted,
                      let prompt = question["question"]?.string else { return nil }
                return QuestionRequest.Question(id: qid, header: question["header"]?.string ?? "OMP",
                    prompt: prompt,
                    choices: (question["options"]?.array ?? []).compactMap { row in
                        row["label"]?.string.map { .init(label: $0, detail: row["description"]?.string) }
                    }, allowsMultiple: question["multi"]?.bool ?? false, allowsOther: true, isSecret: false,
                    recommendedIndex: question["recommended"]?.int)
            }
            guard !questions.isEmpty, questions.count == askQuestions.count else { return nil }
            if method == "ask" { responseFormat = .ask }
        } else {
            guard method != "ask" else { return nil }
            let options = method == "confirm" ? ["Yes", "No"] : frame["options"]?.array?.compactMap(\.string) ?? []
            let details = frame["optionDetails"]?.array ?? []
            questions = [QuestionRequest.Question(id: id, header: "OMP",
                prompt: [frame["title"]?.string, frame["message"]?.string].compactMap { $0 }.joined(separator: "\n"),
                choices: options.enumerated().map { index, label in
                    .init(label: label, detail: details.indices.contains(index) ? details[index]["description"]?.string : nil)
                }, allowsMultiple: false, allowsOther: method == "input" || method == "editor", isSecret: false,
                isMultiline: method == "editor", prefill: frame["prefill"]?.string,
                placeholder: frame["placeholder"]?.string, preservesWhitespace: method == "editor")]
        }
        let deadline = frame["timeout"]?.double.flatMap { milliseconds -> Date? in
            guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
            return now.addingTimeInterval(min(milliseconds / 1_000, 604_800))
        }
        let nativeChoices = frame["options"]?.array
        let labels = nativeChoices?.compactMap(\.string) ?? []
        let toolApproval = method == "select" && nativeChoices?.count == labels.count
            ? (frame["title"]?.string).flatMap { OMPToolApproval(prompt: $0, choices: labels) } : nil
        return QuestionRequest(id: id, questions: questions, deadline: deadline, responseFormat: responseFormat, toolApproval: toolApproval)
    }

    /// Confirmations have approval controls while the native dialog remains the
    /// authority for response serialization, cancellation and timeouts.
    static func approval(for request: QuestionRequest, frame: JSONValue) -> ApprovalRequest? {
        if let tool = request.toolApproval {
            return ApprovalRequest(id: request.id, instanceID: request.instanceID, kind: .tool,
                title: tool.name, detail: frame["message"]?.string, reason: tool.reason,
                options: [.init(id: "Deny", title: "Deny", role: .decline),
                          .init(id: tool.onceChoice, title: "Allow", role: .approve)], deadline: request.deadline, tool: tool)
        }
        guard request.responseFormat == .confirmation else { return nil }
        return ApprovalRequest(id: request.id, instanceID: request.instanceID, kind: .confirmation,
            title: frame["title"]?.string ?? "", detail: frame["message"]?.string,
            options: [.init(id: "No", title: "Deny", role: .decline),
                      .init(id: "Yes", title: "Allow", role: .approve)], deadline: request.deadline)
    }

    static func response(to request: QuestionRequest, answers: [String: QuestionAnswer]) -> JSONValue {
        var response: [String: JSONValue] = ["type": "extension_ui_response", "id": .string(request.id)]
        if request.isAsk {
            let rows: [JSONValue] = request.questions.map { question in
                let answer = answers[question.id] ?? QuestionAnswer(skipped: true)
                let selected = question.choices.map(\.label).filter { answer.selectedOptions.contains($0) }
                var row: [String: JSONValue] = ["id": .string(question.id), "selectedOptions": []]
                if answer.skipped || (selected.isEmpty && answer.customInput == nil) {
                    let skipped = AppText.localized("The user skipped this question without answering.")
                    if request.responseFormat == .encodedAsk {
                        // The older SDK presentation adapter preserves an empty
                        // input plus a separate note as an explicit unanswered row.
                        row["customInput"] = ""
                        row["note"] = .string(skipped)
                    } else {
                        // Native ask trims empty custom input and has no note/skip
                        // field. Keep the user's non-answer explicit without
                        // selecting an option or cancelling the native tool.
                        row["customInput"] = .string(skipped)
                    }
                } else if let text = answer.customInput {
                    row["customInput"] = .string(text)
                } else {
                    row["selectedOptions"] = .array((question.allowsMultiple ? selected : Array(selected.prefix(1))).map(JSONValue.string))
                }
                return .object(row)
            }
            if request.responseFormat == .encodedAsk {
                let payload: JSONValue = ["kind": "submit", "results": .array(rows)]
                response["value"] = .string(String(decoding: payload.data(), as: UTF8.self))
            } else {
                response["answers"] = .array(rows)
            }
        } else if answers.isEmpty {
            response["cancelled"] = true
        } else if request.responseFormat == .confirmation {
            response["confirmed"] = .bool(answers[request.id]?.selectedOptions.first == "Yes")
        } else {
            let answer = answers[request.id]
            response["value"] = .string(answer?.customInput ?? answer?.selectedOptions.first ?? "")
        }
        return .object(response)
    }
}
