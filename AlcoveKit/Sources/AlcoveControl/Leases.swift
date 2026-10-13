import Foundation

/// One advisory lease per VM; the holder's token lets mutating operations through.
struct LeaseTable {
    struct Lease {
        let token: String
        let owner: String
        var expires: ContinuousClock.Instant
    }

    private var leases: [String: Lease] = [:]

    /// The unexpired lease of `vm`; an expired one is removed.
    mutating func active(vm: String, now: ContinuousClock.Instant) -> Lease? {
        guard let lease = leases[vm] else { return nil }
        if lease.expires <= now { leases[vm] = nil; return nil }
        return lease
    }

    /// Grants or renews; throws ControlError.failed when another token holds an unexpired lease.
    mutating func acquire(vm: String, owner: String, ttl: Duration, token: String?, now: ContinuousClock.Instant) throws -> Lease {
        if let current = active(vm: vm, now: now) {
            guard token == current.token else {
                throw ControlHandler.ControlError.failed(LeaseTable.refusalText(vm: vm, lease: current, now: now))
            }
            let renewed = Lease(token: current.token, owner: current.owner, expires: now + ttl)
            leases[vm] = renewed
            return renewed
        }
        let lease = Lease(token: UUID().uuidString, owner: owner, expires: now + ttl)
        leases[vm] = lease
        return lease
    }

    /// Removes the lease of `vm`; a VM without a lease is a no-op.
    mutating func release(vm: String, token: String, now: ContinuousClock.Instant = .now) throws {
        guard let current = active(vm: vm, now: now) else { return }
        guard current.token == token else {
            throw ControlHandler.ControlError.failed("lease token does not match; only the holder can release '\(vm)'")
        }
        leases[vm] = nil
    }

    /// nil when the op may run.
    mutating func refusal(vm: String, token: String?, now: ContinuousClock.Instant) -> String? {
        guard let current = active(vm: vm, now: now), token != current.token else { return nil }
        return LeaseTable.refusalText(vm: vm, lease: current, now: now)
    }

    private static func refusalText(vm: String, lease: Lease, now: ContinuousClock.Instant) -> String {
        let remaining = now.duration(to: lease.expires)
        let seconds = Int((Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18).rounded(.up))
        return "VM '\(vm)' is leased by \(lease.owner) for another \(max(1, seconds)) s; pass its lease token, wait, or ask the owner to release it"
    }
}
