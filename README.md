# Finance — Native Mac Finance Manager

Native SwiftUI macOS app to manage accounts, import OFX bank data (file + direct server), track envelope budgets, and sync recurring bills to Apple Calendar.

## What it does (v1)

- **Accounts** — Checking/savings/credit. Balances from OFX ledger balance.
- **OFX import** — Best-effort path: download `.ofx` from any bank site and drag-import. Parser handles OFX 1.x SGML *and* 2.x XML, deduplicates by FITID so re-imports are safe.
- **Direct OFX sync** — For banks still exposing `OFXHome` (e.g. some credit unions), enter bank URL + credentials. Password is stored **only in Keychain**, statement is fetched via HTTPS POST and parsed with the same parser. Most US banks have disabled this — if so, use file import.
- **Transactions** — Searchable, filterable table. Categorize inline; spending is auto-summed per category.
- **Envelope budget (monthly)** — Assign `$` to categories (Housing, Groceries, Dining, Transport, Utilities, Entertainment, Health, Savings, Debt, Other). Shows spent vs allocated with progress, color turns red over budget.
- **Bills & Calendar** — Create recurring bills (name, amount, due day 1–28, category). Requests EventKit access and syncs bills as events into a dedicated **“Finance Bills”** calendar in Apple Calendar (12 months ahead, one-click resync). Upcoming-in-30-days view in app.
- **Scheduled income** — Same screen now supports paydays (`kindRaw == credit`). Both bills and incomes feed forecasting + Calendar.
- **Cash Flow Forecast** — Month-by-month projection (6/12/24 mo) from starting balance (sum of accounts) + scheduled transactions + envelope estimates (same-category bills subtracted to avoid double count). Chart (balance line + monthly net bars), projected low/ending KPIs, intra-month low (paycheck timing), and a “first negative month” warning. Current month counts only remaining events and pro-rates envelopes; trailing 3-month averages are fallbacks when you haven’t scheduled income/envelopes.

All data lives locally in SwiftData on your Mac. Nothing syncs to a server except your bank’s OFX endpoint (if you enable it) and Apple Calendar (local + your iCloud if you use it).

## Build & run

Requires Xcode 15+ / macOS 14+, Swift 5.10+.

```bash
# from this folder
swift build
swift test
```

For GUI runs, open the **app bundle project** — not `Package.swift`. Running the bare SwiftPM executable in Xcode has no `CFBundleIdentifier`, so macOS never makes it key (typing in sheets beeps) and `linkd.autoShortcut` / intents / Process Registry logs `Code=4097` then kills the debugger with exit 9.

```bash
xcodegen generate          # if needed, creates Finance.xcodeproj
open Finance.xcodeproj     # select Finance scheme → Run ⌘R (now a real .app with ID com.finance.Finance)
# or CLI:
xcodebuild -project Finance.xcodeproj -scheme Finance -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Finance-*/Build/Products/Debug/Finance.app
```

> Tip: after `swift test` passes, try Import & Sync with the sample file `Tests/FinanceTests/Resources/sample.ofx`, then edit envelopes and request Calendar access.

> **Migration note:** `RecurringBill` gained `kindRaw` (default `debit` = expense) for income schedules. Legacy rows load as bills. If your local SwiftData store was created before this column, delete the old app container (or fix `FinanceApp` to use a new `ModelConfiguration` name) if you see a schema mismatch on launch — safe for this dev-stage app.

## Project structure

```
Sources/Finance/
  FinanceApp.swift           @main + SwiftData container
  Models.swift               @Model Account, TransactionRecord, Envelope, RecurringBill, OFXProfile
  OFX/
    OFXParser.swift          SGML+XML tree parser, date/amount handling, request builder
    OFXClient.swift          HTTPS POST to OFXHome + KeychainStore (Security.framework)
  Services/
    Services.swift           TransactionImportService (dedupe UPSERT), BudgetService, CalendarService (EventKit)
    ForecastService.swift    CashFlowForecastService (pure, testable) + ForecastMonth/Event DTOs in Models.swift
  Views/
    ContentView.swift        Sidebar navigation (incl. Cash Flow Forecast)
    DashboardView / AccountsView / TransactionsView / BudgetView / CalendarView / ForecastView / ImportView / SettingsView
Tests/FinanceTests/
  OFXParserTests.swift       SGML, XML, date tests against sample.ofx
  CashFlowForecastTests.swift Income/bills roll-forward, envelope double-count, intra-month low
```

## Roadmap (suggested v2)

1. Recurring transaction rules + auto-categorization (merchant → category map).
2. ~~Cash-flow forecast (project balance from scheduled bills + envelopes).~~ Done — see Cash Flow Forecast.
3. Biweekly/weekend-aware paydays + Plaid fallback for banks that dropped OFX.
4. CSV/QFX import + investment statements (INVSTMT).
5. iCloud sync toggle (SwiftData + CloudKit, still local-first).
6. App Store sandbox + notarization config.

## Security notes

- Credentials: Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Never in UserDefaults/SwiftData.
- OFX TLS: use HTTPS only; verify host. Password is inserted server-side only, never logged.
- Calendar: minimum access — writes only `Finance Bills` calendar.
- File import: no credentials needed, safest default.

## OFX background

Learn more: [OFX spec overview](https://en.wikipedia.org/wiki/Open_Financial_Exchange). OFX files are SGML-like; many banks have migrated to Plaid/Aggregators, which is why file import remains the compatibility baseline.
