import Foundation
import Observation

/// One value under its own observation. A view that reads a thread or project through
/// its cell depends on that item alone, so a change to any other item never re-renders it.
@MainActor
@Observable
final class ObservedValue<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
