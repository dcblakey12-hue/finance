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
        Task { @MainActor in
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
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
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
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
        }
    }
}
