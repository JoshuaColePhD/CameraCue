import SwiftUI

struct LanguageModelSettingsView: View {
    @ObservedObject var settings: LanguageModelSettings
    var showsDone = true
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ScriptModelProvider
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey = ""
    @State private var modelIDs: [String] = []
    @State private var notice: String?
    @State private var hasError = false
    @State private var isWorking = false
    @State private var operation: Task<Void, Never>?
    @State private var loadedCredentialAccount: String?
    @State private var savedAPIKey = ""
    @State private var workspaceID: String

    init(settings: LanguageModelSettings = .shared, showsDone: Bool = true) {
        self.settings = settings; self.showsDone = showsDone
        _provider = State(initialValue: settings.selected.provider)
        _baseURL = State(initialValue: settings.selected.baseURL)
        _model = State(initialValue: settings.selected.model)
        _workspaceID = State(initialValue: settings.selected.workspaceID ?? "")
    }
    private var profile: ScriptModelProfile {
        ScriptModelProfile(provider: provider, baseURL: baseURL, model: model,
                           workspaceID: provider == .anthropic && !workspaceID.isEmpty ? workspaceID : nil)
    }
    private var editsAreSaved: Bool { profile == settings.selected && apiKey == savedAPIKey }
    private var endpointBinding: Binding<String> {
        Binding(get: { baseURL }, set: { value in
            baseURL = value
            let account = try? profile.credentialAccount()
            if account != loadedCredentialAccount {
                apiKey = ""; savedAPIKey = ""; loadedCredentialAccount = account; modelIDs = []
            }
            notice = nil
        })
    }
    private var keyBinding: Binding<String> { Binding(get: { apiKey }, set: { apiKey = $0; notice = nil }) }
    private var modelBinding: Binding<String> { Binding(get: { model }, set: { model = $0; notice = nil }) }
    private var workspaceBinding: Binding<String> { Binding(get: { workspaceID }, set: { workspaceID = $0; notice = nil }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cpu").font(.system(size: 24)).foregroundStyle(StudioPalette.violet)
                    .frame(width: 46, height: 46).background(StudioPalette.lavender, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your AI model").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Use Apple's model or connect one of your own.")
                        .font(.callout).foregroundStyle(StudioPalette.mutedInk)
                }
                Spacer()
                if showsDone { Button("Done") { dismiss() }.buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction) }
            }.padding(24).background(StudioPalette.surface)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MODEL SOURCE").font(.caption.bold()).foregroundStyle(StudioPalette.mutedInk)
                        Picker("Model source", selection: $provider) {
                            ForEach(ScriptModelProvider.allCases) { Text($0.name).tag($0) }
                        }.labelsHidden().accessibilityLabel("Model source")
                        HStack {
                            if !provider.editableEndpoint && provider != .apple {
                                Text(provider.baseURL).textSelection(.enabled).font(.caption).foregroundStyle(StudioPalette.mutedInk)
                            }
                            Spacer()
                            if let guide = provider.guideURL { Link("Setup guide ↗", destination: guide).font(.caption) }
                        }
                    }
                    if provider == .apple {
                        Label("On your Mac", systemImage: "desktopcomputer").font(.headline)
                        Text("Uses Apple Intelligence on a compatible Mac with macOS 26 or later. macOS downloads and manages the model. No API key is needed.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text(settings.selected.provider == .apple ? settings.status : "Choose this source to use Apple's on-device model.")
                            .font(.callout).foregroundStyle(StudioPalette.mutedInk)
                    } else {
                        if provider.editableEndpoint {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("API base URL").font(.callout.bold())
                                TextField(provider.baseURL, text: endpointBinding).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("API base URL").autocorrectionDisabled()
                                Text("HTTPS for remote servers; HTTP is supported on localhost.")
                                    .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(provider.requiresKey ? "Your API key" : "API key (if your server needs one)").font(.callout.bold())
                            SecureField("Stored in macOS Keychain", text: keyBinding).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("API key").autocorrectionDisabled()
                            HStack {
                                Text("Your key stays in Keychain and is sent only to this API address.")
                                    .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                                Spacer()
                                Button("Remove saved key") { removeKey() }.font(.caption).disabled(savedAPIKey.isEmpty)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Text model").font(.callout.bold())
                                Spacer()
                                Button("Fetch models") { start(.models) }.buttonStyle(StudioButtonStyle())
                            }
                            HStack {
                                TextField("Enter a model ID or fetch your models", text: modelBinding)
                                    .textFieldStyle(.roundedBorder).accessibilityLabel("Model ID").autocorrectionDisabled()
                                if !modelIDs.isEmpty {
                                    Menu("Choose") {
                                        ForEach(modelIDs, id: \.self) { id in Button(id) { model = id; notice = nil } }
                                    }.accessibilityLabel("Choose a fetched model")
                                }
                            }
                            Text("Choose a model that supports text chat. Availability depends on your server or API account.")
                                .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                        }
                        if provider == .anthropic {
                            DisclosureGroup("Workspace options") {
                                VStack(alignment: .leading, spacing: 6) {
                                    TextField("Workspace ID (optional)", text: workspaceBinding).textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Claude workspace ID")
                                    Text("Supply a workspace ID if your API key has access to multiple workspaces.")
                                        .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                                }.padding(.top, 8)
                            }
                        }
                        Label(profile.isLoopback ? "Your local model server" : "Your provider, your account", systemImage: profile.isLoopback ? "desktopcomputer" : "network")
                            .font(.headline)
                        Text(disclosure).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(StudioPalette.mutedInk)
                        if provider == .ollama || provider == .lmStudio {
                            Text("Start the server and download a model in \(provider.name), then fetch its models here. CameraCue does not install model weights.")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let notice {
                        Label(notice, systemImage: hasError ? "exclamationmark.triangle" : "info.circle")
                            .font(.callout).foregroundStyle(hasError ? StudioPalette.coral : StudioPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("model-settings-notice")
                    }
                }.padding(24).disabled(isWorking)
            }
            Divider()
            HStack(spacing: 12) {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption)
                    Button("Cancel request") { operation?.cancel() }.buttonStyle(StudioButtonStyle())
                } else {
                    Text(editsAreSaved ? "Selected: \(settings.selected.provider.name)" : "Changes are not saved")
                        .font(.caption).foregroundStyle(StudioPalette.mutedInk).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(provider == .apple ? "Check availability" : "Test connection") { start(.test) }
                    .buttonStyle(StudioButtonStyle()).disabled(isWorking)
                Button("Save model") { save() }.buttonStyle(StudioButtonStyle(primary: true)).disabled(isWorking)
            }.padding(20).background(StudioPalette.surface)
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720, minHeight: 560, idealHeight: 680, maxHeight: 760)
        .background(StudioPalette.canvas).foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.violet).preferredColorScheme(.light)
        .onAppear { settings.refreshCredentialReadiness(); loadKey() }
        .onChange(of: provider) { _, value in
            let saved = settings.profile(for: value)
            baseURL = saved.baseURL; model = saved.model; modelIDs = []; notice = nil
            workspaceID = saved.workspaceID ?? ""
            loadKey()
        }
        .onDisappear { operation?.cancel(); apiKey = "" }
    }
    private var disclosure: String {
        if profile.isLoopback {
            return "AI actions send your prompt and relevant script text directly to this local server. Your server may use cloud models if you configured it that way."
        }
        return "AI actions send your prompt and relevant script text directly to this provider. Usage follows your own API account's billing and limits. Testing sends one short sample request and may incur a provider charge."
    }
    private func loadKey() {
        apiKey = ""
        savedAPIKey = ""
        loadedCredentialAccount = try? profile.credentialAccount()
        do { apiKey = try settings.apiKey(for: profile); savedAPIKey = apiKey }
        catch { show(error.localizedDescription, error: true) }
    }
    private func save() {
        do {
            try settings.save(profile, apiKey: apiKey)
            baseURL = settings.selected.baseURL; model = settings.selected.model
            workspaceID = settings.selected.workspaceID ?? ""
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            savedAPIKey = apiKey
            show("Saved. New AI actions use \(profile.provider.name). A saved configuration is not a connection test.")
        } catch { show(error.localizedDescription, error: true) }
    }
    private func removeKey() {
        do { try settings.removeKey(for: profile); apiKey = ""; savedAPIKey = ""; show("The saved key was removed from this Mac.") }
        catch { show(error.localizedDescription, error: true) }
    }
    private enum Operation { case models, test }
    private func start(_ action: Operation) {
        operation?.cancel()
        isWorking = true; notice = nil
        let profile = profile, key = apiKey
        operation = Task { @MainActor in
            defer { isWorking = false }
            do {
                if action == .models {
                    let ids = try await settings.fetchModels(profile: profile, apiKey: key)
                    try Task.checkCancellation()
                    modelIDs = ids
                    show("Found \(modelIDs.count) models. Choose a text chat model, or enter its ID.")
                } else {
                    try await settings.testConnection(profile: profile, apiKey: key)
                    try Task.checkCancellation()
                    show(profile.provider == .apple ? "Apple Intelligence is available on this Mac." : "Connection succeeded. The selected model returned text.")
                }
            } catch is CancellationError { show("Request cancelled.") }
            catch { show(error.localizedDescription, error: true) }
        }
    }
    private func show(_ message: String, error: Bool = false) { notice = message; hasError = error }
}
