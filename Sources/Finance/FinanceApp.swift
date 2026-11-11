import SwiftUI
import SwiftData
import AppKit

@main
struct FinanceApp: App {
    // Proper .app bundles are activatable by LaunchServices; SwiftPM bare
    // executables are not — they never become key, so sheets beep on typing
    // and linkd complains about missing bundle ID. Activating here lets the
    // SwiftPM fallback path still get keyboard focus.
    init() {
        if DemoMode.isOn { DemoMode.resetSettings() }
        Task { @MainActor in
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            // CloudKit tells the Mac about changes from the iPhone with a silent push. Without
            // registering, the Mac only picks them up at launch or when it's brought to the front.
            NSApplication.shared.registerForRemoteNotifications()
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Account.self,
            TransactionRecord.self,
            Envelope.self,
            RecurringBill.self,
            OFXProfile.self,
            CategoryRule.self,
            CustomCategory.self,
        ])
        // Demo mode: made-up data in memory only, never synced (see DemoMode).
        if DemoMode.isOn {
            do { return try DemoMode.makeContainer(schema: schema) }
            catch { fatalError("Could not create the demo ModelContainer: \(error)") }
        }
        // iCloud sync is on only when Info.plist's FinanceCloudContainer names a CloudKit
        // container (e.g. "iCloud.com.you.finance"); empty keeps the data local.
        let cloudID = (Bundle.main.object(forInfoDictionaryKey: "FinanceCloudContainer") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                        cloudKitDatabase: cloudID.isEmpty ? .none : .private(cloudID))
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .defaultAppStorage(DemoMode.isOn ? DemoMode.defaults : .standard)
                .onAppear {
                    // Make sure the main window is key + main so the first
                    // sheet (Add Account) can grab first responder.
                    if let window = NSApp.keyWindow ?? NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .newItem) {
                Divider()
                Button("Back Up Data…") { BackupCoordinator.shared.backUp(sharedModelContainer.mainContext) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Restore from Backup…") { BackupCoordinator.shared.chooseRestore(sharedModelContainer.mainContext) }
                Button("Start New Empty File…") { BackupCoordinator.shared.startNew(sharedModelContainer.mainContext) }
                Divider()
                Button(DemoMode.isOn ? "Leave Demo Mode" : "Show Demo Data…") { DemoMode.confirmAndSwitch() }
            }
        }
    }
}
