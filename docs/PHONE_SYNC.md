# Phone companion (iCloud sync) — plan

Goal: an iPhone app that shows and edits the same data as the Mac app, synced through the
user's private iCloud (SwiftData + CloudKit). No server.

## Done (Mac app is ready for it)
- Models have no unique constraints and every stored property has a default (CloudKit rules).
- `DedupeService` merges duplicates a two-device sync can create (runs at launch).

## Needs an Apple Developer account (paid)
1. Create an iCloud container, e.g. `iCloud.com.<you>.finance`.
2. Mac target: sign with the team; add the iCloud capability (CloudKit) and Push Notifications
   (remote notifications background mode on iOS). In `project.yml` add the entitlements
   `com.apple.developer.icloud-services: [CloudKit]` and `com.apple.developer.icloud-container-identifiers`.
3. In `FinanceApp.swift` set the container's `cloudKitDatabase: .private("iCloud.com.<you>.finance")`
   (it is `.none` today).
4. First launch after enabling: the existing local data uploads to iCloud.

## iOS app (next)
- Move `Models.swift` and `Services/` into a Swift package shared by the Mac and iOS targets.
- iOS screens: balances, upcoming scheduled items, calendar with projected balances,
  scheduled-transaction add/edit, transaction list with recategorize.
- OFX/QFX import stays on the Mac; the phone receives the data over sync.

## Gotchas
- CloudKit schema is append-only in production: add fields, don't rename or remove them.
- Test sync with the Development environment before promoting the schema to Production.
