// Linking the system framework lets Xcode 27 inspect the empty App Intents metadata without a warning.
#if canImport(AppIntents)
import AppIntents
#endif
import SwiftUI
import UIKit

@main
struct TranthorExampleApp: App {
    @UIApplicationDelegateAdaptor(ExampleAppDelegate.self) private var appDelegate
    @StateObject private var model = ExampleModel()
    @StateObject private var push = ExamplePushModel.shared
    var body: some Scene { WindowGroup { ExampleView(model: model, push: push).task { model.attachPush(push); await model.start() } } }
}

struct ExampleView: View {
    @ObservedObject var model: ExampleModel
    @ObservedObject var push: ExamplePushModel
    @State private var showLog = false
    var body: some View {
        NavigationView {
            Form {
                if model.reachable == false {
                    Section { Label("Network unreachable. Events are kept and retried when the network is back.", systemImage: "wifi.slash").foregroundColor(.orange) }
                }
                Section("Workspace") {
                    SecureField("Write key", text: Binding(get: { model.writeKey }, set: model.editKey))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("writeKey")
                    TextField("Host", text: Binding(get: { model.host }, set: model.editHost))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("User ID", text: $model.enteredUserId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("userIdInput")
                    Button(model.configured ? "Reconfigure" : "Configure") { Task { await model.configure() } }
                        .disabled(model.configuring).accessibilityIdentifier("configure")
                    Button("Forget key") { Task { await model.forgetKey() } }
                        .disabled(model.configuring).accessibilityIdentifier("forgetKey")
                    Text(model.configured ? "Configured" : "Not configured").accessibilityIdentifier("configurationStatus")
                    if model.keyFromLaunch { Text("Launch-only key; it is not saved to Keychain.").font(.caption) }
                }
                Section("Send tagged events") {
                    Button("Identify") { Task { await model.identify() } }
                    Toggle("Slow flush (\(model.flushIntervalMs / 1000, specifier: "%.3g") s)", isOn: Binding(get: { model.slowFlush }, set: { enabled in Task { await model.setSlowFlush(enabled) } }))
                        .accessibilityIdentifier("slowFlush")
                    Text(model.flushIntervalText).accessibilityIdentifier("flushInterval")
                    Button("Track (no auto flush)") { Task { await model.send(.track) } }.accessibilityIdentifier("track")
                    Text("Accepted event calls this launch: \(model.acceptedCalls)").accessibilityIdentifier("acceptedCalls")
                    Stepper("Burst: \(model.burstCount)", value: $model.burstCount, in: 1...1000)
                    Button("Track burst of \(model.burstCount)") { Task { await model.send(.track, count: model.burstCount) } }
                    // Two default-style buttons in one Form row all fire on any tap in the row; borderless ones act alone.
                    // A borderless button is only as large as its label, so each label fills its half of the row.
                    HStack(spacing: 0) {
                        Button { Task { await model.send(.page) } } label: {
                            Text("Page").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.accessibilityIdentifier("page")
                        Button { Task { await model.send(.screen) } } label: {
                            Text("Screen").frame(maxWidth: .infinity, alignment: .trailing).contentShape(Rectangle())
                        }.accessibilityIdentifier("screen")
                    }.buttonStyle(.borderless)
                    Button(model.flushing ? "Flushing…" : "Flush") { Task { await model.flush() } }
                        .disabled(model.flushing).accessibilityIdentifier("flush")
                }.disabled(!model.configured || model.configuring)
                Section("Consent & offline test") {
                    Button(model.optedOut ? "Opt in" : "Opt out") { Task { await model.changeConsent() } }
                        .disabled(!model.configured || model.configuring)
                    Button("Reset identity") { Task { await model.reset() } }.disabled(!model.configured || model.configuring)
                    Toggle("Simulate offline: show instructions", isOn: $model.offlineInstructions)
                    if model.offlineInstructions {
                        Text("On iPhone, enable Airplane Mode and turn Wi-Fi off in Settings or Control Center. Send events, then reconnect. This toggle only shows instructions; it does not alter SDK transport. Simulator follows the Mac's network.")
                            .font(.caption)
                    }
                }
                Section("Live state") {
                    LabeledContentCompat(label: "Anonymous ID", value: model.anonymousId)
                    LabeledContentCompat(label: "User ID", value: model.userId)
                    Text("Queue count: unavailable in the public SDK API").font(.caption)
                    Text("Last flush: \(model.lastFlush)").accessibilityIdentifier("flushResult")
                    Text("Run ID: \(model.runId)").font(.caption).textSelection(.enabled)
                    Button("View log (\(model.lines.count)/200)") { showLog = true }
                }
                Section("Terminal error callbacks (\(model.errors.count))") {
                    if model.errors.isEmpty { Text("None") }
                    ForEach(Array(model.errors.enumerated()), id: \.offset) { _, entry in Text(entry).font(.caption) }
                }
                Section("Push preview (optional module)") {
                    Text("Real APNs delivery needs a paid Apple Developer account. The default build has no push entitlement.").font(.caption)
                    Text("Preview ID: \(push.previewDeliveryId)").font(.caption).accessibilityIdentifier("pushPreviewId")
                    Button("Request notification permission") { Task { await push.requestPermission() } }
                        .accessibilityIdentifier("pushPermission")
                    Button("Preview local notification") { Task { await push.preview() } }
                        .disabled(!model.configured || model.optedOut || model.configuring).accessibilityIdentifier("pushPreview")
                    Button("Preview notification with image") { Task { await push.preview(withImage: true) } }
                        .disabled(!model.configured || model.optedOut || model.configuring).accessibilityIdentifier("pushImagePreview")
                    Button("Register with APNs (requires entitlement)") { UIApplication.shared.registerForRemoteNotifications() }
                        .disabled(!push.hasConfiguredEnvironment)
                    Text(push.hasConfiguredEnvironment ? "APNs environment: \(push.environment.rawValue)" : "Set TRANTHOR_APNS_ENVIRONMENT in Local.xcconfig before registering.").font(.caption)
                    Text("Permission: \(push.authorization)")
                    Text(push.tokenStatus).font(.caption)
                    Text(push.registration).font(.caption)
                    Text(push.categoryStatus).font(.caption).accessibilityIdentifier("pushCategoryStatus")
                    Text("Push observations: \(push.observations)").accessibilityIdentifier("pushObservations")
                    Text(push.lastObservation).accessibilityIdentifier("pushLastObservation")
                }
            }.navigationTitle("Tranthor Example")
                .sheet(isPresented: $showLog) {
                    NavigationView {
                        ScrollView { Text(model.lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }
                            .navigationTitle("Live test log")
                            .toolbar {
                                ToolbarItem(placement: .navigationBarLeading) { Button("Done") { showLog = false } }
                                ToolbarItem(placement: .navigationBarTrailing) { Button("Copy") { UIPasteboard.general.string = model.lines.joined(separator: "\n") } }
                            }
                    }
                }
        }.navigationViewStyle(.stack)
    }
}
private struct LabeledContentCompat: View {
    let label: String
    let value: String
    var body: some View { VStack(alignment: .leading) { Text(label).font(.caption).foregroundColor(.secondary); Text(value).font(.caption).textSelection(.enabled) } }
}
