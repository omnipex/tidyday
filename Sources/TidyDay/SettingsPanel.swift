import SwiftUI

/// 模型設定：選引擎、填 API key／Base URL／模型、測試連線
struct SettingsPanel: View {
    @Environment(\.appLanguage) private var lang
    @AppStorage(Engine.storageKey) private var engineRaw = Engine.apple.rawValue
    @State private var model = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var result: String?
    @State private var resultIsError = false
    let onClose: () -> Void

    private var s: Strings { lang.strings }
    private var engine: Engine { Engine(rawValue: engineRaw) ?? .apple }
    private var config: CloudConfig { CloudConfig(engine: engine, model: model, baseURL: baseURL, apiKey: apiKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconButton(systemName: "chevron.left", help: s.back, action: onClose)
                Text(s.modelSettings).font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(s.engineLabel) {
                        Picker("", selection: $engineRaw) {
                            ForEach(Engine.allCases) { e in
                                Text(name(e)).tag(e.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    if engine == .apple {
                        notice(s.appleInfo, systemImage: "lock.shield", tint: .green)
                    } else {
                        if engine.needsKey {
                            field(s.apiKey, note: s.keychainNote) {
                                SecureField("sk-…", text: $apiKey)
                                    .textFieldStyle(.plain)
                                    .modifier(FieldStyle())
                            }
                        }
                        if engine.hasBaseURL {
                            field(s.baseURL) {
                                TextField(engine.defaultBaseURL, text: $baseURL)
                                    .textFieldStyle(.plain)
                                    .modifier(FieldStyle())
                            }
                        }
                        field(s.modelLabel) {
                            HStack(spacing: 6) {
                                TextField(engine.modelPlaceholder, text: $model)
                                    .textFieldStyle(.plain)
                                    .modifier(FieldStyle())
                                if models.isEmpty {
                                    Button(action: loadModels) {
                                        if loadingModels { ProgressView().controlSize(.small) } else { Text(s.loadModels) }
                                    }
                                    .buttonStyle(SecondaryButtonStyle(compact: true))
                                    .disabled(loadingModels)
                                } else {
                                    Menu {
                                        ForEach(models, id: \.self) { m in Button(m) { model = m } }
                                    } label: { Text(s.chooseModel(models.count)) }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                }
                            }
                        }
                        if config.isOnDevice {
                            notice(s.ollamaLocal, systemImage: "lock.shield", tint: .green)
                        } else {
                            notice(s.cloudPrivacy(engine.brand ?? ""), systemImage: "exclamationmark.triangle", tint: .orange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: test) {
                            HStack(spacing: 7) {
                                if testing { ProgressView().controlSize(.small).tint(.white) }
                                Text(testing ? s.testing : s.testConnection)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(testing)

                        if let result {
                            Label(result, systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(resultIsError ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: engineRaw) { _, _ in loadFields() }
        .onChange(of: model) { _, v in UserDefaults.standard.set(v, forKey: CloudConfig.modelKey(engine)) }
        .onChange(of: baseURL) { _, v in UserDefaults.standard.set(v, forKey: CloudConfig.baseURLKey(engine)) }
        .onChange(of: apiKey) { _, v in Keychain.set(v, for: engine.rawValue); models = [] }
    }

    private func name(_ e: Engine) -> String { e.brand ?? s.engineApple }

    private func loadFields() {
        let c = CloudConfig.load(engine)
        model = c.model
        baseURL = c.baseURL
        apiKey = c.apiKey
        models = []
        result = nil
    }

    private func loadModels() {
        loadingModels = true
        result = nil
        Task {
            defer { loadingModels = false }
            do {
                models = try await CloudClient.listModels(config)
            } catch {
                result = error.localizedDescription
                resultIsError = true
            }
        }
    }

    /// 用一句範例實際跑一次整理，確認 key、模型和格式都通
    private func test() {
        if let reason = Organizer.unavailableReason(s, engine: engine) {
            result = reason
            resultIsError = true
            return
        }
        testing = true
        result = nil
        let lang = lang
        let engine = engine
        Task {
            defer { testing = false }
            do {
                let out = try await Organizer.parse(lang.strings.testSample, openTodos: [], lang: lang, engine: engine)
                let preview = out.items.map { "[\(lang.strings.label($0.kind))] \($0.text)" }.joined(separator: "；")
                result = lang.strings.testOK(out.items.count, preview)
                resultIsError = false
            } catch {
                result = error.localizedDescription
                resultIsError = true
            }
        }
    }

    private func field<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            content()
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
        }
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 9).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
    }
}
