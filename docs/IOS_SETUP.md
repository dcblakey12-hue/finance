# Adding the iPhone target in Xcode (one time)

The phone app's code is in `Finance iOS/`. It shares these files with the Mac app
(each file is compiled into both targets — no copies):

- `Sources/Finance/Models.swift`
- `Sources/Finance/Services/Services.swift`
- `Sources/Finance/Services/CategorizationService.swift`
- `Sources/Finance/Services/ScheduleService.swift`
- `Sources/Finance/Services/ForecastService.swift`
- `Sources/Finance/Services/SubscriptionService.swift`

Steps:
1. File → New → Target… → iOS → App. Product name `Finance iOS`, team = yours, Interface SwiftUI,
   Storage **None**, bundle id `com.blakey.Finance.iOS`. Minimum deployment: iOS 17.
2. Delete the template's `ContentView.swift` and `...App.swift`; add the five files in
   `Finance iOS/` to the new target (drag in, tick only the iOS target).
3. For each shared file above: select it, and in the File inspector (right panel) tick **both** targets
   under Target Membership.
4. iOS target → Signing & Capabilities: add **iCloud** (CloudKit, container `iCloud.com.blakey.finance`),
   **Background Modes** → Remote notifications, and **Push Notifications** if offered.
5. iOS target → Info tab: add a custom property `FinanceCloudContainer` (String) = `iCloud.com.blakey.finance`.
6. Run on your iPhone (Developer Mode on) or a simulator signed in to iCloud.

The Mac app owns the category list; the phone doesn't seed defaults.
