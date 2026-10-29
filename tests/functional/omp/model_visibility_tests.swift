import Foundation
@testable import OMPGUI

@main
struct ModelVisibilityChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }

    @MainActor static func main() async throws {
        guard CaptureRun.outputDirectory?.path.contains("/build.noindex/verification/runs/") == true,
              let defaults = CaptureRun.defaults else { fatalError("Require isolated defaults") }
        defaults.removePersistentDomain(forName: CaptureRun.suiteName)
        defer { defaults.removePersistentDomain(forName: CaptureRun.suiteName) }

        let deepseek = (0..<18).map { ModelOption(id: "deepseek/model-\($0)", name: "Model \($0)", provider: "deepseek") }
        let kimi = [ModelOption(id: "kimi-code/model-0", name: "Model 0", provider: "kimi-code")]
        let catalogue = deepseek + kimi
        let pin = ModelPin(provider: .omp, modelID: deepseek[0].id)
        let otherPin = ModelPin(provider: .omp, modelID: kimi[0].id)
        let preference = ModelPreference(effort: "high", fastMode: true)
        let legacyList = try JSONEncoder().encode([pin])
        defaults.set(legacyList, forKey: "modelList")
        defaults.set(try JSONEncoder().encode([pin.id: preference]), forKey: "modelPreferences")

        let model = AppModel()
        let settings = model.settings
        model.providers.updateCatalog(catalogue, for: .omp)
        func ids() -> [String] { ModelCatalog.entries(model).map(\.option.id) }
        expect(ids() == catalogue.map(\.id), "All native models start visible in catalogue order, including more than fifteen models")
        expect(settings.hiddenModels.isEmpty, "A retired allow-list never becomes a hidden-model list")
        expect(settings.preference(for: .omp, model: pin.modelID) == preference, "Existing per-model defaults survive the visibility change")

        settings.remember(model: pin.modelID, effort: "high", for: .omp)
        settings.setModelHidden(true, pin)
        expect(!ids().contains(pin.modelID) && ids().contains(otherPin.modelID),
               "A hidden current/remembered model stays out of the picker without hiding another provider's same-named model")
        expect(AppSettings().isModelHidden(pin), "Hidden choices persist across settings reloads")
        settings.setModelHidden(true, pin)
        expect(settings.hiddenModels.count == 1, "Repeated hiding remains idempotent")
        settings.setModelHidden(false, pin)
        expect(ids() == catalogue.map(\.id), "Enabling a model restores its native catalogue position")
        expect(!AppSettings().isModelHidden(pin), "Enabling is persisted as well as hiding")

        settings.setModelHidden(true, otherPin)
        settings.setModelsHidden(true, models: deepseek)
        expect(ids().isEmpty && settings.hiddenModels.count == catalogue.count,
               "Provider-wide hiding includes every model beyond the old limit and keeps an existing hidden provider unchanged")
        settings.setModelHidden(false, pin)
        expect(ids() == [pin.modelID], "One model can be enabled after hiding its whole provider")
        settings.setModelsHidden(false, models: deepseek)
        expect(ids() == deepseek.map(\.id) && settings.isModelHidden(otherPin),
               "Provider-wide enabling restores only that provider and preserves another provider's hidden choices")
        settings.setModelsHidden(true, models: [])
        settings.setModelsHidden(false, models: [])
        expect(ids() == deepseek.map(\.id), "Empty provider catalogues cannot clear unrelated choices")

        settings.setModelsHidden(true, models: catalogue)
        expect(ids().isEmpty, "Hiding every model leaves the picker empty instead of falling back to all models")
        let reopened = AppModel()
        reopened.providers.updateCatalog(catalogue, for: .omp)
        expect(ModelCatalog.entries(reopened).isEmpty, "An entirely hidden catalogue remains empty after reopening")
        let newModel = ModelOption(id: "deepseek/new-model", name: "New model", provider: "deepseek")
        model.providers.updateCatalog(catalogue + [newModel], for: .omp)
        expect(ids() == [newModel.id], "Newly discovered models are visible by default while existing choices remain hidden")
        model.providers.updateCatalog(kimi, for: .omp)
        model.providers.updateCatalog(catalogue, for: .omp)
        expect(ids().isEmpty, "A temporarily unavailable model retains its hidden choice when it returns")

        settings.setModelsHidden(false, models: catalogue)
        expect(ids() == catalogue.map(\.id) && AppSettings().hiddenModels.isEmpty, "Enabling all restores the full catalogue durably")
        expect(settings.preference(for: .omp, model: pin.modelID) == preference,
               "Single and bulk visibility changes never reset model defaults")
        expect(settings.lastModel(for: .omp) == pin.modelID, "Hiding does not switch the selected/remembered model")
        expect(defaults.data(forKey: "modelList") == legacyList, "Legacy stored data is not reinterpreted or rewritten")
        expect(model.liveRuntimes.isEmpty && reopened.liveRuntimes.isEmpty,
               "Changing picker visibility does not start a native session")
        checks += try await ModelMetadataChecks.run(root: CaptureRun.outputDirectory!)
        print("Model catalogue checks passed: \(checks)")
    }
}
