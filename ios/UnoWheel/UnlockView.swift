import OnewheelKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown when a board on server-issued firmware has no saved response yet.
struct UnlockView: View {
    @Environment(BoardConnection.self) private var connection
    @State private var pasted = ""
    @State private var importing = false
    @State private var candidates: [Data] = []
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This board's firmware only accepts a response issued by Future Motion's server. The official app saves it the first time it connects. Grab it once and UnoWheel keeps it in your Keychain; the board's challenge never changes, so it works forever.")
                        .font(.callout)
                }

                if let challenge = connection.challenge {
                    Section("Board challenge") {
                        Text(challenge.bytes.spacedHex)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        ShareLink(item: challenge.hex) { Label("Share challenge", systemImage: "square.and.arrow.up") }
                    }
                }

                Section {
                    Button("Import PacketLogger capture", systemImage: "doc.badge.arrow.up") { importing = true }
                    ForEach(candidates, id: \.self) { candidate in
                        Button {
                            submit(candidate)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(candidate.spacedHex).font(.caption.monospaced())
                                if let challenge = connection.challenge, Handshake.isPlausibleResponse(candidate, for: challenge) {
                                    Text("Matches this board").font(.caption2).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                } header: {
                    Text("From a capture")
                } footer: {
                    Text("Record the official app connecting with the iOS Bluetooth logging profile and PacketLogger, then open the .pklg here.")
                }

                Section("Paste a response") {
                    TextField("40 hex characters", text: $pasted, axis: .vertical)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Unlock") {
                        if let data = Handshake.parseHex(pasted) { submit(data) } else { error = "That isn't hex." }
                    }
                    .disabled(pasted.filter(\.isHexDigit).count != 40 || working)
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Unlock \(connection.displayName ?? "board")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Disconnect") { connection.disconnect() }
                }
                if working {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "pklg") ?? .data, .data]) { result in
                load(result)
            }
        }
    }

    private func load(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let findings = PacketLoggerCapture.findings(in: try Data(contentsOf: url))
            candidates = findings.responses
            if candidates.isEmpty {
                error = "No unlock response in that capture. Make sure it covers the official app connecting."
            } else if candidates.count == 1 {
                submit(candidates[0])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit(_ response: Data) {
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await connection.submit(response)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
