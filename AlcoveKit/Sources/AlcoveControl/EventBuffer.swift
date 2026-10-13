import Foundation
import AlcoveAgent
import AlcoveQMP

/// One event the guest agent sent, numbered in arrival order.
public struct GuestEvent: Sendable, Equatable {
    /// Position in the VM's event sequence; the first event is 1.
    public let seq: Int
    /// Host time of arrival.
    public let time: Date
    public let name: String
    /// The event's fields without its name.
    public let payload: JSON

    public init(seq: Int, time: Date, name: String, payload: JSON) {
        self.seq = seq
        self.time = time
        self.name = name
        self.payload = payload
    }

    /// `{seq, time, name, ...payload}`; `time` is ISO 8601 with milliseconds, and `seq`, `time` and `name` win over payload fields of the same name.
    var json: JSON {
        var obj = payload.objectValue ?? [:]
        obj["seq"] = .int(Int64(seq))
        obj["time"] = .string(TraceEntry.format(time))
        obj["name"] = .string(name)
        return .object(obj)
    }

    /// The title of the event's window: `window.title`, or `title` when the fields are flat.
    var windowTitle: String? {
        payload["window"]?["title"]?.stringValue ?? payload["title"]?.stringValue
    }
}

/// The guest events of one VM. Keeps the newest `capacity` events; sequence numbers keep counting when older events are dropped.
public actor EventBuffer {
    public static let capacity = 500

    private var events: [GuestEvent] = []
    private var last = 0

    public init() {}

    public func append(name: String, payload: JSON, at time: Date) {
        last += 1
        events.append(GuestEvent(seq: last, time: time, name: name, payload: payload))
        if events.count > EventBuffer.capacity { events.removeFirst(events.count - EventBuffer.capacity) }
    }

    /// The kept events with a sequence number above `seq`, oldest first, and the sequence number of the newest event ever appended (0 when none).
    public func since(_ seq: Int) -> (events: [GuestEvent], next: Int) {
        (events.filter { $0.seq > seq }, last)
    }

    /// Appends the agent events of `client`, without their `t` and `name` fields, until the client disconnects or the returned task is cancelled.
    /// The task is the one reader of `client.events`; cancelling it ends that stream.
    public nonisolated func follow(_ client: AgentClient, now: @escaping @Sendable () -> Date = { Date() }) -> Task<Void, Never> {
        let stream = client.events
        return Task {
            for await event in stream {
                if Task.isCancelled { return }
                switch event {
                case .agent(let name, let message):
                    var fields = message.objectValue ?? [:]
                    fields["t"] = nil
                    fields["name"] = nil
                    await self.append(name: name, payload: .object(fields), at: now())
                case .disconnected:
                    return
                case .clipboardChanged, .resolution:
                    continue
                }
            }
        }
    }
}
