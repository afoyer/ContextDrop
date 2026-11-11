import Observation
import SwiftUI

/// Tabs of the workspace window (R3 board 1): one chat per tab, each with its own folder and provider.
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var tabs: [UUID] = []
    var selected: UUID?
    /// Tabs ⌘-clicked in the strip (shared together).
    var multiSelection: Set<UUID> = []
    /// Direction of the last tab switch, for the slide transition.
    private(set) var direction: Edge = .trailing
    @ObservationIgnored private var closed: [UUID] = []

    var selectedIndex: Int? { selected.flatMap { tabs.firstIndex(of: $0) } }

    /// Opens (or focuses) a conversation as a tab, next to the current one.
    func open(_ id: UUID) {
        if !tabs.contains(id) {
            if let index = selectedIndex { tabs.insert(id, at: index + 1) } else { tabs.append(id) }
        }
        select(id)
    }

    func select(_ id: UUID) {
        guard tabs.contains(id) else { return }
        if let from = selectedIndex, let to = tabs.firstIndex(of: id) { direction = to >= from ? .trailing : .leading }
        selected = id
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// Next / previous tab (swipe, ⌃Tab without anything waiting). Doesn't wrap.
    func move(by delta: Int) {
        guard let index = selectedIndex else { return }
        let next = index + delta
        guard tabs.indices.contains(next) else { return }
        select(tabs[next])
    }

    /// Removes a tab. Returns true if it was open.
    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(of: id) else { return false }
        tabs.remove(at: index)
        multiSelection.remove(id)
        closed.append(id)
        if closed.count > 20 { closed.removeFirst() }
        if selected == id {
            selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
            direction = .leading
        }
        return true
    }

    /// ⌘⇧T: the last closed tab whose chat still exists.
    func reopen(exists: (UUID) -> Bool) -> UUID? {
        while let id = closed.popLast() {
            if exists(id), !tabs.contains(id) {
                open(id)
                return id
            }
        }
        return nil
    }

    /// Drops tabs whose chat is gone.
    func prune(exists: (UUID) -> Bool) {
        let gone = tabs.filter { !exists($0) }
        guard !gone.isEmpty else { return }
        for id in gone { close(id) }
    }

    /// ⌃Tab: the next tab after the current one that is waiting for the user.
    func nextNeedingYou(_ needsYou: (UUID) -> Bool) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let start = selectedIndex ?? -1
        for offset in 1...tabs.count {
            let id = tabs[(start + offset) % tabs.count]
            if needsYou(id) { return id }
        }
        return nil
    }

    func toggleMultiSelect(_ id: UUID) {
        if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
        if let selected { multiSelection.insert(selected) }
        if multiSelection.count == 1 && multiSelection.first == selected { multiSelection.removeAll() }
    }
}
