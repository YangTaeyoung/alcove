import SwiftUI

/// What the menu bar's Virtual Machine commands act on: the session shown in
/// the focused window (or selected in the library), plus how that window
/// wants operations run so their errors surface in its own alert.
struct VMWindowCommands {
    let session: VMSession
    /// Start the VM. The library opens the VM window first so the guest (and
    /// any start error) is visible; a VM window starts in place.
    let start: @MainActor () -> Void
    /// Run `operation` on the session and present any error it records.
    let run: @MainActor (_ operation: @escaping @MainActor (VMSession) async -> Void) -> Void
    /// Present the snapshots sheet in that window.
    let takeSnapshot: @MainActor () -> Void
    /// Ask for confirmation, then reset the guest (unsaved guest work is lost).
    let reset: @MainActor () -> Void
    /// Ask for confirmation, then quit the engine without telling the guest.
    let forceStop: @MainActor () -> Void
    /// Ask for confirmation, then delete the suspend-to-disk image.
    let discardSuspendState: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var vmCommands: VMWindowCommands?
}
