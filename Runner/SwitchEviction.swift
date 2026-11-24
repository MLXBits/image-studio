import Foundation

/// Pattern 5: when the main window's selection (model, precision, or custom checkpoint) moves
/// off the warm model, evict it, debounced so flipping through models doesn't thrash. Never
/// mid-generation: the controller schedules again when the run ends.
final class SwitchEviction {
    /// The main window's selection, as last reported.
    private(set) var selectedKey: String?
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration = .seconds(3)) {
        self.delay = delay
    }

    func select(_ key: String, on driver: MfluxDriverController) {
        selectedKey = key
        schedule(on: driver)
    }

    func cancel() {
        task?.cancel()
    }

    func schedule(on driver: MfluxDriverController) {
        task?.cancel()
        guard let selectedKey, let loaded = driver.loadedSelectionKey, loaded != selectedKey, !driver.isGenerating else {
            return
        }
        task = Task { [weak self, weak driver, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let driver, !driver.isGenerating,
                  driver.loadedSelectionKey != self.selectedKey else { return }
            driver.eject(reason: "model_switch")
        }
    }
}
