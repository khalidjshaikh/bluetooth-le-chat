import SwiftUI

struct ContentView: View {
    @StateObject private var chat = BluetoothChatService()
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionPanel
            Divider()
            messageList
            Divider()
            composer
        }
        .frame(minWidth: 520, minHeight: 620)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("BLE Chat")
                    .font(.headline)

                Spacer()

                if chat.role == .host {
                    HStack(spacing: 6) {
                        Text("Name")
                            .foregroundStyle(.secondary)
                        TextField("Name", text: $chat.localName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }

                Picker("Role", selection: roleBinding) {
                    Text("Idle").tag(BluetoothChatService.Role.idle)
                    Text("Host").tag(BluetoothChatService.Role.host)
                    Text("Join").tag(BluetoothChatService.Role.join)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(chat.isConnected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(chat.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if !chat.messages.isEmpty {
                    Button("Clear") { chat.clearConversation() }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(12)
    }

    private var roleBinding: Binding<BluetoothChatService.Role> {
        Binding(
            get: { chat.role },
            set: { newValue in
                if newValue == .idle {
                    chat.stop()
                } else {
                    chat.start(as: newValue)
                }
            }
        )
    }

    // MARK: - Connection panel

    @ViewBuilder
    private var connectionPanel: some View {
        switch chat.role {
        case .join where !chat.isConnected:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hosts nearby")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Rescan") { chat.start(as: .join) }
                        .buttonStyle(.link)
                }

                if chat.discoveredPeers.isEmpty {
                    Text("Searching… make sure the other Mac is set to Host.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chat.discoveredPeers) { peer in
                        HStack {
                            Text(peer.name)
                            Spacer()
                            Text("\(peer.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Connect") { chat.connect(to: peer) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(12)

        case .host where !chat.isConnected:
            Text("Waiting for the other Mac to join…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

        default:
            EmptyView()
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.count) {
                if let last = chat.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Type a message…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)

            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }

    private var canSend: Bool {
        chat.isConnected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        chat.send(draft)
        draft = ""
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.direction {
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

        case .incoming, .outgoing:
            HStack {
                if message.isOutgoing { Spacer(minLength: 40) }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(message.isOutgoing ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !message.isOutgoing { Spacer(minLength: 40) }
            }
        }
    }
}
