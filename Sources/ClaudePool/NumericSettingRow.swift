import SwiftUI
import Observation

@MainActor @Observable
final class NumericSettingDraft {
    var text: String
    private(set) var savedValue: Double
    var isSaving = false
    var isInvalid = false
    var isEdited: Bool { text != Self.format(savedValue) }

    init(value: Double) { savedValue = value; text = Self.format(value) }
    static func format(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    func edit(_ text: String) { self.text = text; isInvalid = false }
    func receiveSaved(_ value: Double) {
        let preserveDraft = isEdited || isSaving
        savedValue = value
        if !preserveDraft { text = Self.format(value) }
    }
    func cancel() {
        guard !isSaving else { return }
        text = Self.format(savedValue); isInvalid = false
    }
    func finish(with value: Double) {
        savedValue = value; text = Self.format(value); isSaving = false; isInvalid = false
    }
}

struct NumericSettingRow: View {
    @Bindable var model: PoolAppModel
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: String
    let integerOnly: Bool
    let identifier: String
    private let save: @MainActor (Double) async -> Double
    @State private var draft: NumericSettingDraft

    @MainActor init(model: PoolAppModel, title: String, value: Double, range: ClosedRange<Double>, unit: String,
                   identifier: String, integerOnly: Bool = false, save: @escaping @MainActor (Double) async -> Double) {
        self.model = model; self.title = title; self.value = value; self.range = range
        self.unit = unit; self.identifier = identifier; self.integerOnly = integerOnly; self.save = save
        _draft = State(initialValue: NumericSettingDraft(value: value))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 7) {
                Text(model.t(title)).font(.system(size: 11))
                Spacer(minLength: 8)
                TextField(model.t(title), text: Binding(get: { draft.text }, set: { draft.edit($0) }),
                          prompt: Text(NumericSettingDraft.format(value)))
                    .textFieldStyle(.roundedBorder).controlSize(.small).font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.trailing).frame(width: 62)
                    .disabled(model.isWorking || draft.isSaving)
                    .accessibilityIdentifier(identifier)
                    .help(rangeHint)
                    .onSubmit(submit)
                Text(model.t(unit)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                Button(model.t("Save"), action: submit).controlSize(.small)
                    .disabled(model.isWorking || draft.isSaving || !draft.isEdited)
                    .accessibilityIdentifier(identifier + ".save")
            }
            if draft.isInvalid {
                Text(rangeHint).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .onChange(of: value) { _, value in draft.receiveSaved(value) }
        .onExitCommand { draft.cancel() }
    }
    private var rangeHint: String {
        model.t(integerOnly ? "Whole number: {0}–{1}" : "Range: {0}–{1}", NumericSettingDraft.format(range.lowerBound), NumericSettingDraft.format(range.upperBound))
    }
    private func submit() {
        guard !model.isWorking, !draft.isSaving else { return }
        let input = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = integerOnly ? Int(input).map(Double.init) : Double(input)
        guard let submitted = number, submitted.isFinite, range.contains(submitted) else {
            draft.isInvalid = true; return
        }
        guard submitted != draft.savedValue else { draft.finish(with: submitted); return }
        draft.isInvalid = false; draft.isSaving = true
        Task { @MainActor in draft.finish(with: await save(submitted)) }
    }
}
