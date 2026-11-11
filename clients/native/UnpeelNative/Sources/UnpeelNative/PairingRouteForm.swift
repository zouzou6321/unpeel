import Foundation
import Network
import SwiftUI

/// What a freshly minted pairing code should carry.
enum PairingRoute: Equatable, Sendable {
    case lan
    case publicOnly(host: String, port: UInt16)
    case both(host: String, port: UInt16)
}

enum PairingPath: String, CaseIterable, Identifiable {
    case lan
    case publicAddress
    case both

    var id: String { rawValue }
}

/// Asks for the path before a QR is shown. A public address is saved only
/// after this Mac opens `http://ip:port/mobile/pair` and gets the pairing
/// service's own error back.
struct PairingRouteForm: View {
    @ObservedObject private var localization = LocalizationStore.shared
    var onSave: (PairingRoute) -> Void

    @State private var path: PairingPath
    @State private var host: String
    @State private var portText: String
    @State private var reachability: Reachability = .idle

    init(onSave: @escaping (PairingRoute) -> Void) {
        self.onSave = onSave
        let defaults = UserDefaults.standard
        _path = State(initialValue: PairingPath(rawValue: defaults.string(forKey: Keys.path) ?? "") ?? .lan)
        _host = State(initialValue: defaults.string(forKey: Keys.host) ?? "")
        _portText = State(initialValue: defaults.string(forKey: Keys.port) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Choose how this code connects"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.foreground)

            Picker(L10n.t("Choose how this code connects"), selection: $path) {
                Text(L10n.t("Local network")).tag(PairingPath.lan)
                Text(L10n.t("Public address")).tag(PairingPath.publicAddress)
                Text(L10n.t("Both")).tag(PairingPath.both)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            if path != .lan {
                HStack(spacing: 8) {
                    TextField(L10n.t("Public IP"), text: $host)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.t("Port"), text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                }

                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(reachability == .reachable ? Color.green : (reachability == .unreachable ? Color.red : Theme.mutedForeground))
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.t("The live terminal uses a second port. Until that port is forwarded, public connections fall back to ordinary fetching."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.t("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .task(id: probeKey) { await probe() }
    }

    private var explanation: String {
        switch path {
        case .lan:
            return L10n.t("The code carries this Mac's local address.")
        case .publicAddress:
            return L10n.t("The code carries only the public address. Fill in the IP and port. This Mac checks that it can open them before saving.")
        case .both:
            return L10n.t("The code keeps this Mac's local address, so an iPhone scans it as before. An Android phone also remembers the public address, uses it when the local network does not answer, and switches back as soon as the local network does.")
        }
    }

    private var statusText: String {
        switch reachability {
        case .idle, .invalid:
            return L10n.t("Enter the public IPv4 address and the forwarded port.")
        case .checking:
            return L10n.t("Checking whether this Mac can open that address…")
        case .reachable:
            return L10n.t("This Mac can reach that address.")
        case .unreachable:
            return L10n.t("This Mac could not open that address. The IP and port have to reach this Mac's pairing service.")
        }
    }

    private var canSave: Bool {
        path == .lan || reachability == .reachable
    }

    private var parsedAddress: (host: String, port: UInt16)? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIPv4(trimmed),
              let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0
        else { return nil }
        return (trimmed, port)
    }

    private var probeKey: String {
        switch path {
        case .lan:
            return "lan"
        case .publicAddress, .both:
            return "\(path.rawValue)|\(host)|\(portText)"
        }
    }

    @MainActor
    private func probe() async {
        guard path != .lan else {
            reachability = .idle
            return
        }
        guard let address = parsedAddress else {
            reachability = .invalid
            return
        }
        reachability = .checking
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        let ok = await PublicAddressProbe.reachesUnpeel(host: address.host, port: address.port)
        guard !Task.isCancelled else { return }
        reachability = ok ? .reachable : .unreachable
    }

    private func save() {
        let route: PairingRoute
        switch path {
        case .lan:
            route = .lan
        case .publicAddress, .both:
            guard let address = parsedAddress, reachability == .reachable else { return }
            route = path == .publicAddress
                ? .publicOnly(host: address.host, port: address.port)
                : .both(host: address.host, port: address.port)
        }
        let defaults = UserDefaults.standard
        defaults.set(path.rawValue, forKey: Keys.path)
        defaults.set(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.host)
        defaults.set(portText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.port)
        onSave(route)
    }

    static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let value = Int(octet), (0...255).contains(value) else { return false }
            return String(value) == octet
        }
    }

    private enum Reachability: Equatable {
        case idle
        case invalid
        case checking
        case reachable
        case unreachable
    }

    private enum Keys {
        static let path = "unpeel.pairingRoute"
        static let host = "unpeel.publicPairingHost"
        static let port = "unpeel.publicPairingPort"
    }
}

enum PublicAddressProbe {
    /// True when cleartext HTTP to `/mobile/pair` comes back from this Host's
    /// pairing service. Any other listener fails the check.
    static func reachesUnpeel(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let holder = ConnectionHolder()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let box = ProbeBox(continuation)
                let connection = NWConnection(
                    host: NWEndpoint.Host(host),
                    port: nwPort,
                    using: .tcp
                )
                holder.store(connection)
                box.connection = connection
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = """
                        POST /mobile/pair HTTP/1.1\r
                        Host: \(host):\(port)\r
                        Content-Type: application/json\r
                        Content-Length: 2\r
                        Connection: close\r
                        \r
                        {}
                        """
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                            if error != nil {
                                box.finish(false)
                                return
                            }
                            read(connection, into: box, buffer: Data())
                        })
                    case .failed(_):
                        box.finish(false)
                    case .cancelled:
                        box.finish(false)
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                    box.finish(false)
                }
                if holder.isCancelled {
                    connection.cancel()
                }
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private static func read(_ connection: NWConnection, into box: ProbeBox, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if error != nil || isComplete || next.count >= 4096 {
                let text = String(decoding: next, as: UTF8.self)
                let ok = text.contains("HTTP/1.") && text.contains("pairing")
                box.finish(ok)
                return
            }
            read(connection, into: box, buffer: next)
        }
    }

    private final class ConnectionHolder: @unchecked Sendable {
        let lock = NSLock()
        private var connection: NWConnection?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func store(_ connection: NWConnection) {
            lock.lock()
            self.connection = connection
            let cancelled = self.cancelled
            lock.unlock()
            if cancelled { connection.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let connection = self.connection
            lock.unlock()
            connection?.cancel()
        }
    }

    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        var connection: NWConnection?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let connection = self.connection
            lock.unlock()
            connection?.cancel()
            continuation?.resume(returning: value)
        }
    }
}
