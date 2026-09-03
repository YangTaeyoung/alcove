import SwiftUI

extension View {
    /// Confirmation before `VMSession.discardSuspendState()`, shared by the VM
    /// window, the library and the settings sheet so the wording matches.
    ///
    /// `target` is the session whose saved session is about to be deleted; it
    /// is cleared when the dialog closes. `action` performs the discard the way
    /// the presenting window reports errors (its own alert, or the library's).
    func confirmDiscardSuspendState(_ target: Binding<VMSession?>,
                                    action: @escaping @MainActor (VMSession) -> Void) -> some View {
        confirmationDialog("Discard the suspended state of “\(target.wrappedValue?.name ?? "")”?",
                           isPresented: Binding(get: { target.wrappedValue != nil },
                                                set: { if !$0 { target.wrappedValue = nil } }),
                           presenting: target.wrappedValue) { session in
            Button("Discard Suspended State", role: .destructive) { action(session) }
        } message: { _ in
            Text("The saved session is deleted and the next start boots from scratch. "
                 + "Everything the guest held in memory when it was suspended is lost; its disks are unaffected.")
        }
    }
}
