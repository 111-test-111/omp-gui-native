import Foundation

/// A provider asking for permission before it acts.
struct ApprovalRequest: Identifiable, Sendable {
    enum Kind: Sendable {
        case command
        case fileChange
        case tool
        case permissions
        case plan
        case confirmation
    }

    struct Option: Identifiable, Hashable, Sendable {
        enum Role: Sendable {
            case approve
            case approveAlways
            case decline
            case cancel
        }

        var id: String
        var title: String
        var role: Role
    }

    var id: String
    var instanceID = UUID()
    var kind: Kind
    var title: String
    var detail: String?
    var reason: String?
    var options: [Option]
    var toolItemID: String?
    var deadline: Date? = nil
    var tool: OMPToolApproval? = nil

    /// One denial and one single-call allowance; never substitute a session grant.
    var decisions: [Option] {
        [options.first { $0.role == .decline }, options.first { $0.role == .approve }].compactMap { $0 }
    }

    var headline: String {
        switch kind {
        case .command: "Run this command?"
        case .fileChange: "Apply these changes?"
        case .tool: "Allow this action?"
        case .permissions: "Grant extra access?"
        case .plan: "Ready to build this plan?"
        case .confirmation: "Allow this action?"
        }
    }

}

/// A provider asking the user to choose or type an answer.
struct QuestionRequest: Identifiable, Sendable {
    struct Question: Identifiable, Hashable, Sendable {
        var id: String
        var header: String
        var prompt: String
        var choices: [Choice]
        var allowsMultiple: Bool
        var allowsOther: Bool
        var isSecret: Bool
        var isMultiline: Bool = false
        var prefill: String? = nil
        var placeholder: String? = nil
        /// Editors must preserve whitespace and allow an intentionally empty answer.
        var preservesWhitespace: Bool = false
        var recommendedIndex: Int? = nil

        func isRecommended(_ index: Int) -> Bool {
            if let recommendedIndex { return index == recommendedIndex }
            return choices[index].label.lowercased().hasSuffix(" (recommended)")
        }
    }

    struct Choice: Hashable, Sendable {
        var label: String
        var detail: String?
    }

    var id: String
    var instanceID = UUID()
    var questions: [Question]
    var deadline: Date? = nil
    enum ResponseFormat: Sendable { case value, confirmation, ask, encodedAsk }
    var responseFormat: ResponseFormat = .value
    var toolApproval: OMPToolApproval? = nil

    var isAsk: Bool { responseFormat == .ask || responseFormat == .encodedAsk }
}

/// Keep typed input distinct even when it is identical to an option's label.
struct QuestionAnswer: Equatable, Sendable {
    var selectedOptions: [String] = []
    var customInput: String? = nil
    var skipped = false

    init(selectedOptions: [String] = [], customInput: String? = nil, skipped: Bool = false) {
        self.selectedOptions = selectedOptions
        self.customInput = customInput
        self.skipped = skipped
    }

    var isAnswered: Bool { skipped || !selectedOptions.isEmpty || customInput != nil }
}

/// Shared by windows displaying the same conversation's live question form.
struct QuestionDraft {
    var page = 0
    var isSubmitting = false
    private(set) var values: [String: QuestionAnswer] = [:]

    init(_ request: QuestionRequest) {
        for question in request.questions {
            if let prefill = question.prefill, !prefill.isEmpty || question.preservesWhitespace {
                values[question.id] = QuestionAnswer(customInput: prefill)
            } else {
                let recommended = question.choices.indices.filter { question.isRecommended($0) }
                let indices = question.allowsMultiple ? recommended : Array(recommended.prefix(1))
                values[question.id] = QuestionAnswer(selectedOptions: indices.map { question.choices[$0].label })
            }
        }
    }

    mutating func clearSubmittedValues() { values.removeAll(); page = 0; isSubmitting = false }

    mutating func pick(_ label: String, for question: QuestionRequest.Question) {
        var selected = values[question.id]?.selectedOptions ?? []
        if selected.contains(label) { selected.removeAll { $0 == label } }
        else if question.allowsMultiple { selected.append(label) }
        else { selected = [label] }
        values[question.id] = QuestionAnswer(selectedOptions: selected)
    }

    mutating func write(_ text: String, for question: QuestionRequest.Question) {
        var value = values[question.id] ?? QuestionAnswer()
        value.customInput = text
        value.skipped = false
        if !text.isEmpty { value.selectedOptions = [] }
        values[question.id] = value
    }

    mutating func skip(_ question: QuestionRequest.Question) {
        values[question.id] = QuestionAnswer(skipped: true)
    }

    func answers(for request: QuestionRequest) -> [String: QuestionAnswer] {
        var result: [String: QuestionAnswer] = [:]
        for question in request.questions {
            var value = values[question.id] ?? QuestionAnswer()
            if question.preservesWhitespace {
                value.customInput = value.customInput ?? ""
            } else {
                let text = value.customInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                value.customInput = text.isEmpty ? nil : text
            }
            result[question.id] = value
        }
        return result
    }

    func unansweredCount(_ request: QuestionRequest) -> Int {
        answers(for: request).values.filter { !$0.isAnswered }.count
    }
}
