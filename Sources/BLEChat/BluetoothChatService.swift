import Foundation
import CoreBluetooth

struct DiscoveredPeer: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
}

/// Runs both sides of the BLE link:
///
/// * **Host**  — advertises the chat service (peripheral role) and receives
///              messages through write requests on the RX characteristic.
/// * **Join**  — scans for a host (central role), connects, and writes to the
///              host's RX characteristic.
///
/// Either side can send at any time: the host pushes outbound messages as
/// notifications on the TX characteristic, the joiner pushes outbound messages
/// as writes on RX. A single connection therefore carries traffic both ways.
@MainActor
final class BluetoothChatService: NSObject, ObservableObject {

    enum Role: String, CaseIterable, Identifiable {
        case idle = "Idle"
        case host = "Host"
        case join = "Join"

        var id: String { rawValue }
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status = "Choose Host or Join to begin."
    @Published private(set) var isConnected = false
    @Published private(set) var peerName: String?
    @Published private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published private(set) var role: Role = .idle
    @Published var localName: String = BluetoothChatService.defaultName() {
        didSet {
            if localName.count > 12 {
                localName = String(localName.prefix(12))
            }
        }
    }

    // Central (Join) role
    private var central: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var remoteRX: CBCharacteristic?
    private var remoteTX: CBCharacteristic?

    // Peripheral (Host) role
    private var peripheralManager: CBPeripheralManager?
    private var rxCharacteristic: CBMutableCharacteristic?
    private var txCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []

    // Desired state, applied once the managers report `.poweredOn`.
    private var wantsHost = false
    private var wantsJoin = false

    // Outbound notification queue (peripheral role flow control).
    private var notificationQueue: [Data] = []

    // Reassembly buffers for incoming frames.
    private var partialMessages: [UInt16: [UInt16: Data]] = [:]
    private var nextMessageID: UInt16 = 0

    private var advertisedName: String {
        let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "BLE-Chat" : String(trimmed.prefix(12))
    }

    private static func defaultName() -> String {
        let suffix = String(UUID().uuidString.prefix(4))
        return "Mac-\(suffix)"
    }

    // MARK: - Public API

    func start(as role: Role) {
        stop()
        self.role = role

        switch role {
        case .host:
            wantsHost = true
            wantsJoin = false
            status = "Preparing to host…"
            let manager = ensurePeripheralManager()
            if manager.state == .poweredOn { beginHosting() }
        case .join:
            wantsHost = false
            wantsJoin = true
            status = "Preparing to scan…"
            let manager = ensureCentral()
            if manager.state == .poweredOn { beginScanning() }
        case .idle:
            status = "Choose Host or Join to begin."
        }
    }

    func stop() {
        wantsHost = false
        wantsJoin = false
        role = .idle

        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        subscribedCentrals.removeAll()
        notificationQueue.removeAll()

        central?.stopScan()
        if let peripheral = connectedPeripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        remoteRX = nil
        remoteTX = nil
        discoveredPeers.removeAll()

        isConnected = false
        peerName = nil
        partialMessages.removeAll()
        status = "Choose Host or Join to begin."
    }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(.outgoing(text))
        let frames = ChatFraming.encode(messageID: nextMessageID, text: text)
        nextMessageID &+= 1
        transmit(frames)
    }

    func connect(to peer: DiscoveredPeer) {
        guard role == .join, let central else { return }
        central.stopScan()
        connectedPeripheral = peer.peripheral
        peer.peripheral.delegate = self
        peerName = peer.name
        status = "Connecting to “\(peer.name)”…"
        central.connect(peer.peripheral, options: nil)
    }

    func clearConversation() {
        messages.removeAll()
    }

    // MARK: - Transmission

    private func transmit(_ frames: [Data]) {
        switch role {
        case .host:
            enqueueNotifications(frames)
        case .join:
            guard let peripheral = connectedPeripheral, let rx = remoteRX else { return }
            for frame in frames {
                peripheral.writeValue(frame, for: rx, type: .withResponse)
            }
        case .idle:
            break
        }
    }

    private func enqueueNotifications(_ frames: [Data]) {
        notificationQueue.append(contentsOf: frames)
        drainNotificationQueue()
    }

    private func drainNotificationQueue() {
        guard let manager = peripheralManager, let tx = txCharacteristic else { return }
        while !notificationQueue.isEmpty {
            let frame = notificationQueue[0]
            if manager.updateValue(frame, for: tx, onSubscribedCentrals: nil) {
                notificationQueue.removeFirst()
            } else {
                break
            }
        }
    }

    // MARK: - Reception

    private func ingest(_ data: Data) {
        guard let frame = ChatFraming.decode(data) else { return }

        var parts = partialMessages[frame.messageID] ?? [:]
        parts[frame.sequence] = frame.payload
        partialMessages[frame.messageID] = parts

        guard parts.count == Int(frame.total) else { return }

        var payload = Data()
        for index in 0..<frame.total {
            if let part = parts[index] { payload.append(part) }
        }
        partialMessages[frame.messageID] = nil

        let text = String(decoding: payload, as: UTF8.self)
        guard !text.isEmpty else { return }
        messages.append(.incoming(text))
    }

    // MARK: - Manager setup

    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        let manager = CBCentralManager(delegate: self, queue: .main)
        central = manager
        return manager
    }

    private func ensurePeripheralManager() -> CBPeripheralManager {
        if let peripheralManager { return peripheralManager }
        let manager = CBPeripheralManager(delegate: self, queue: .main)
        peripheralManager = manager
        return manager
    }

    // MARK: - Host (peripheral) role

    private func beginHosting() {
        guard let manager = peripheralManager, manager.state == .poweredOn else { return }

        let rx = CBMutableCharacteristic(
            type: ChatProtocol.rxCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let tx = CBMutableCharacteristic(
            type: ChatProtocol.txCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        rxCharacteristic = rx
        txCharacteristic = tx

        let service = CBMutableService(type: ChatProtocol.serviceUUID, primary: true)
        service.characteristics = [rx, tx]

        manager.removeAllServices()
        manager.add(service)
    }

    private func beginAdvertising() {
        guard let manager = peripheralManager, manager.state == .poweredOn else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [ChatProtocol.serviceUUID]
        ])
        status = "Hosting as “\(advertisedName)”. Waiting for a peer to join…"
    }

    // MARK: - Join (central) role

    private func beginScanning() {
        guard let central, central.state == .poweredOn else { return }
        discoveredPeers.removeAll()
        central.scanForPeripherals(withServices: [ChatProtocol.serviceUUID], options: nil)
        status = "Scanning for hosts nearby…"
    }

    private func resetConnection() {
        connectedPeripheral = nil
        remoteRX = nil
        remoteTX = nil
        isConnected = false
        peerName = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothChatService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if wantsJoin { beginScanning() }
            case .poweredOff:
                status = "Bluetooth is off. Turn it on in Control Center."
            case .unauthorized:
                status = "Bluetooth permission denied. Grant access in System Settings › Privacy & Security › Bluetooth."
            case .unsupported:
                status = "This Mac does not support Bluetooth LE."
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Unknown host"

        MainActor.assumeIsolated {
            if let index = discoveredPeers.firstIndex(where: { $0.id == peripheral.identifier }) {
                let existing = discoveredPeers[index]
                discoveredPeers[index] = DiscoveredPeer(
                    id: existing.id,
                    name: name,
                    rssi: RSSI.intValue,
                    peripheral: peripheral
                )
            } else {
                discoveredPeers.append(
                    DiscoveredPeer(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral)
                )
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            status = "Connected. Discovering services…"
            peripheral.discoverServices([ChatProtocol.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            resetConnection()
            status = "Could not connect\(error.map { ": \($0.localizedDescription)" } ?? ".")"
            if wantsJoin { beginScanning() }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            resetConnection()
            messages.append(.system("Peer disconnected."))
            status = "Disconnected. Scanning again…"
            if wantsJoin { beginScanning() }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothChatService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == ChatProtocol.serviceUUID }) else {
                status = "Chat service not found on peer."
                return
            }
            peripheral.discoverCharacteristics(
                [ChatProtocol.rxCharacteristicUUID, ChatProtocol.txCharacteristicUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case ChatProtocol.txCharacteristicUUID:
                    remoteTX = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case ChatProtocol.rxCharacteristicUUID:
                    remoteRX = characteristic
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == ChatProtocol.txCharacteristicUUID else { return }
            if characteristic.isNotifying {
                isConnected = true
                peerName = peripheral.name ?? peerName ?? "Peer"
                status = "Connected to “\(peerName ?? "Peer")”. You can chat now."
                messages.append(.system("Connected to \(peerName ?? "peer")."))
            } else {
                isConnected = false
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == ChatProtocol.txCharacteristicUUID,
              let data = characteristic.value else { return }
        MainActor.assumeIsolated { ingest(data) }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BluetoothChatService: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            switch peripheral.state {
            case .poweredOn:
                if wantsHost { beginHosting() }
            case .poweredOff:
                status = "Bluetooth is off. Turn it on in Control Center."
            case .unauthorized:
                status = "Bluetooth permission denied. Grant access in System Settings › Privacy & Security › Bluetooth."
            case .unsupported:
                status = "This Mac does not support Bluetooth LE."
            default:
                break
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                status = "Failed to publish service: \(error.localizedDescription)"
                return
            }
            beginAdvertising()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        MainActor.assumeIsolated {
            if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
                subscribedCentrals.append(central)
            }
            isConnected = true
            peerName = "Peer \(central.identifier.uuidString.prefix(4))"
            status = "A peer joined. You can chat now."
            messages.append(.system("A peer joined the chat."))
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        MainActor.assumeIsolated {
            subscribedCentrals.removeAll { $0.identifier == central.identifier }
            if subscribedCentrals.isEmpty {
                isConnected = false
                peerName = nil
                messages.append(.system("Peer left the chat."))
                status = subscribedCentrals.isEmpty && wantsHost
                    ? "Hosting as “\(advertisedName)”. Waiting for a peer to join…"
                    : status
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        MainActor.assumeIsolated {
            for request in requests {
                if let value = request.value {
                    ingest(value)
                }
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            drainNotificationQueue()
        }
    }
}
