import AppKit
import SwiftUI
@testable import OMPGUI

@MainActor @Observable
private final class DraftFixture {
    var value: QuestionDraft
    init(_ value: QuestionDraft) { self.value = value }
}

@main
struct AskQuestionChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }

    private static func frame(_ questions: [JSONValue], id: String = "ask") -> JSONValue {
        let payload: JSONValue = ["version": 1, "questions": .array(questions)]
        return ["type": "extension_ui_request", "id": .string(id), "method": "input",
                "title": .string(OMPExtensionDialog.askPrefix + String(decoding: payload.data(), as: UTF8.self))]
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func layout(_ request: QuestionRequest, draft: QuestionDraft, exercise: Bool = false) -> CGSize {
        let stored = DraftFixture(draft)
        let binding = Binding(get: { stored.value }, set: { stored.value = $0 })
        let sheet = QuestionSheet(request: request, draft: binding) { _, delivered in delivered(false) }
            .presentedChrome()
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: sheet)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        expect(size.width == 460 && size.height > 150 && size.height < 540, "Card has a bounded, nonzero size")
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let question = request.questions[draft.page]
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        expect(!scrolls.isEmpty && scrolls[0].frame.height <= 360, "Every question has a bounded native scrolling viewport")
        expect(scrolls[0].superview!.frame.maxY < size.height - 35, "The scrolling question cannot cover the action footer")
        if question.isMultiline {
            expect(descendants(host).contains { ($0 as? NSTextView)?.isEditable == true }, "A native editor is present")
        } else if question.allowsOther || question.choices.isEmpty {
            let fields = descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            expect(fields.count == 1 && fields[0].frame.width > 300 && fields[0].frame.height > 0,
                   "Only the current question's answer field is mounted and usable")
            expect(fields[0].stringValue == (draft.values[question.id]?.customInput ?? ""), "Reopening populates the real native input control")
            if exercise {
                fields[0].stringValue = "Native input 中文"
                fields[0].delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: fields[0]))
                expect(stored.value.values[question.id]?.customInput == "Native input 中文"
                    && stored.value.values[question.id]?.selectedOptions == [],
                       "Editing the real native input updates the form and clears its checked options")
            }
        }
        return size
    }

    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.contains("/build.noindex/verification/runs/") else { fatalError("Require isolated output") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let questions: [JSONValue] = [
            ["id": "single", "header": "单选", "question": "选择一种方式，也可以直接输入其他答案。", "recommended": 1,
             "options": [["label": "A", "description": "第一种方式"], ["label": "B", "description": "第二种方式"]]],
            ["id": "multi", "header": "多选", "question": "选择多个选项，检查来回翻页后的勾选状态。", "multi": true, "recommended": 0,
             "options": [["label": "A", "description": "第一项"], ["label": "B", "description": "第二项"], ["label": "C"]]],
            ["id": "free", "question": "没有选项的自由输入题。", "options": []],
            ["id": "skip", "question": "这道题可以跳过，模型仍应继续。", "options": [["label": "Yes"], ["label": "No"]]],
        ]
        let request = OMPExtensionDialog.request(frame(questions))!
        let nativeRequest = OMPExtensionDialog.request(["type": "extension_ui_request", "id": "native-ask",
            "method": "ask", "questions": .array(questions)])!
        expect(request.isAsk && request.responseFormat == .encodedAsk && request.questions.count == 4,
               "A native input envelope projects the entire ask batch")
        expect(request.questions[1].allowsMultiple && request.questions[1].choices.count == 3,
               "Multi semantics and all choices survive projection")
        expect(request.questions[0].choices[0].detail == "第一种方式", "Option descriptions survive projection")
        var draft = QuestionDraft(request)
        expect(draft.values["single"]?.selectedOptions == ["B"] && draft.values["multi"]?.selectedOptions == ["A"],
               "Native recommended indices initialize the right answers")
        expect(draft.unansweredCount(request) == 2, "Only genuinely unanswered questions remain incomplete")
        let single = request.questions[0], multi = request.questions[1], free = request.questions[2]
        draft.pick("B", for: multi)
        draft.pick("C", for: multi)
        expect(draft.values["multi"]?.selectedOptions == ["A", "B", "C"], "Multi selection accumulates choices")
        draft.pick("C", for: multi)
        expect(draft.values["multi"]?.selectedOptions == ["A", "B"], "Toggling one choice preserves the others")
        draft.write("other", for: multi)
        expect(draft.values["multi"]?.selectedOptions == [], "Typing clears every checked option")
        draft.pick("B", for: multi)
        expect(draft.values["multi"]?.customInput == nil, "Picking an option clears written input")
        draft.pick("A", for: multi)
        draft.write("  B  ", for: single)
        expect(draft.values["single"]?.selectedOptions == [], "Custom input also clears recommended single choices")
        draft.write("你好\n第二行🙂", for: free)
        draft.skip(request.questions[3])
        expect(draft.unansweredCount(request) == 0, "A mixed form can combine choices, custom input and a skipped question")
        let answers = draft.answers(for: request)
        expect(answers["single"]?.customInput == "B" && answers["single"]?.selectedOptions == [],
               "Text identical to an option remains custom input")
        let response = OMPExtensionDialog.response(to: request, answers: answers)
        let nativeResponse = OMPExtensionDialog.response(to: nativeRequest, answers: answers)
        let payload = JSONValue.parse(response["value"]!.string!)!
        expect(payload["results"]?[1]?["selectedOptions"] == ["A", "B"], "Submitted choices use stable question option order")
        expect(payload["results"]?[3]?["customInput"]?.string == "" && payload["results"]?[3]?["note"]?.string?.isEmpty == false,
               "Skip is an explicit unanswered note, never cancellation")
        expect(response["cancelled"] == nil, "Skip must not send native cancellation")
        let nativeSkip = nativeResponse["answers"]?[3]
        expect(nativeSkip?["customInput"]?.string == AppText.localized("The user skipped this question without answering.")
            && nativeSkip?["customInput"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            "Native ask skips retain explicit unanswered text through native whitespace normalization")
        expect(nativeSkip?["selectedOptions"] == [] && nativeSkip?["note"] == nil && nativeResponse["cancelled"] == nil,
            "Native ask skips neither invent a selected option nor rely on unsupported notes or cancellation")
        expect(nativeResponse["answers"]?[0]?["customInput"] == "B"
            && nativeResponse["answers"]?[1]?["selectedOptions"] == ["A", "B"],
            "Direct native ask preserves ordinary custom and multiple-choice answers")
        draft.page = 1
        let reopened = draft
        expect(reopened.page == 1 && reopened.values == draft.values, "The badge can retain page and answers across popover recreation")
        draft.write("", for: single)
        expect(draft.unansweredCount(request) == 1, "Deleting custom input does not silently restore a recommendation")
        draft.write(" ", for: multi)
        expect(draft.unansweredCount(request) == 2, "Whitespace cannot submit stale checked options")
        draft.pick("A", for: single)
        draft.pick("B", for: single)
        expect(draft.values["single"]?.selectedOptions == ["B"], "Single choice still replaces previous picks")
        draft.write("changed", for: request.questions[3])
        expect(draft.values["skip"]?.skipped == false, "Editing a skipped question reactivates its answer")

        var fixtures: [JSONValue] = [["name": "mixed", "questions": .array(questions), "response": response,
                                      "nativeResponse": nativeResponse]]
        for index in questions.indices {
            let question = questions[index]
            let one = OMPExtensionDialog.request(frame([question]))!
            let skipped = OMPExtensionDialog.response(to: one, answers: [:])
            let nativeOne = OMPExtensionDialog.request(["type": "extension_ui_request", "id": "native-ask",
                "method": "ask", "questions": [question]])!
            let nativeSkipped = OMPExtensionDialog.response(to: nativeOne, answers: [:])
            fixtures.append(["name": .string("skip-\(index)"), "questions": [question], "response": skipped,
                             "nativeResponse": nativeSkipped])
            expect(skipped["cancelled"] == nil, "Single-question skips also keep ask alive")
            expect(nativeSkipped["answers"]?[0]?["selectedOptions"] == []
                && nativeSkipped["answers"]?[0]?["customInput"]?.string == AppText.localized("The user skipped this question without answering.")
                && nativeSkipped["cancelled"] == nil, "Every native single-question skip is an explicit non-answer")
        }
        fixtures.append(["name": "skip-batch", "questions": .array(questions),
                         "response": OMPExtensionDialog.response(to: request, answers: [:]),
                         "nativeResponse": OMPExtensionDialog.response(to: nativeRequest, answers: [:])])
        try JSONValue.array(fixtures).data(pretty: true).write(to: root.appendingPathComponent("responses.json"))

        expect(OMPExtensionDialog.request(frame([])) == nil, "An empty batch cannot open an unusable card")
        expect(OMPExtensionDialog.request(frame([questions[0], questions[0]])) == nil, "Duplicate IDs cannot alias unrelated drafts")
        expect(OMPExtensionDialog.request(["id": "bad", "method": "input", "title": .string(OMPExtensionDialog.askPrefix + "invalid")]) == nil,
               "Malformed envelopes fail closed")
        let direct = OMPExtensionDialog.request(["id": "direct", "method": "ask", "questions": .array(questions)])!
        expect(OMPExtensionDialog.response(to: direct, answers: answers)["answers"]?.array?.count == 4,
               "Direct native ask frames retain their structured response shape")
        let editor = OMPExtensionDialog.request(["id": "editor", "method": "editor", "title": "Edit", "prefill": "  first\nsecond\n"])!
        var editDraft = QuestionDraft(editor)
        expect(editDraft.answers(for: editor)["editor"]?.customInput == "  first\nsecond\n", "Editors retain exact prefill whitespace")
        editDraft.write("", for: editor.questions[0])
        expect(editDraft.unansweredCount(editor) == 0 && editDraft.answers(for: editor)["editor"]?.customInput == "",
               "Intentionally empty native editor content remains sendable")
        let confirm = OMPExtensionDialog.request(["id": "confirm", "method": "confirm", "title": "Continue?"])!
        expect(OMPExtensionDialog.response(to: confirm, answers: ["confirm": .init(selectedOptions: ["Yes"])])["confirmed"]?.bool == true,
               "Ordinary native confirmation stays compatible")
        expect(OMPExtensionDialog.response(to: confirm, answers: [:])["cancelled"]?.bool == true,
               "Skipping an ordinary permission dialog retains its cancellation behavior")
        let input = OMPExtensionDialog.request(["id": "input", "method": "input", "title": "Type", "placeholder": "Value"])!
        expect(OMPExtensionDialog.response(to: input, answers: ["input": .init(customInput: " typed ")])["value"]?.string == " typed ",
               "Ordinary input still returns a string")

        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let first = layout(request, draft: reopened, exercise: true)
        var custom = reopened
        custom.page = 0
        let second = layout(request, draft: custom)
        expect(first.width == second.width && second.height < first.height,
               "Each page fits its own choices at one stable width instead of reserving the tallest page")
        custom.page = 2
        expect(layout(request, draft: custom).height < first.height,
               "A free-input page drops the space taller pages need")
        let fiveOptions: [JSONValue] = (0..<5).map { ["label": .string("Option \($0)"), "description": .string("Detail \($0)")] }
        let fiveChoice = OMPExtensionDialog.request(frame([["id": "five", "question": "Pick one of five.", "options": .array(fiveOptions)]]))!
        let threeChoice = OMPExtensionDialog.request(frame([["id": "three", "question": "Pick one of five.", "options": .array(Array(fiveOptions.prefix(3)))]]))!
        let fiveHeight = layout(fiveChoice, draft: QuestionDraft(fiveChoice))
        let threeHeight = layout(threeChoice, draft: QuestionDraft(threeChoice))
        expect(abs(fiveHeight.height - threeHeight.height) <= 1,
               "Choices past the third scroll at the three-choice height")
        _ = layout(editor, draft: editDraft)
        let many = (0..<12).map { index -> JSONValue in
            ["id": .string("q\(index)"), "question": .string(String(repeating: "Long question 中文。", count: 30)),
             "options": .array((0..<20).map { ["label": .string("Option \($0)"), "description": .string(String(repeating: "Details ", count: 15))] }), "multi": .bool(index % 2 == 0)]
        }
        let large = OMPExtensionDialog.request(frame(many))!
        _ = layout(large, draft: QuestionDraft(large))
        print("Ask model, response and headless layout checks passed: \(checks)")
    }
}
