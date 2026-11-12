import SwiftUI
import SwiftData

/// The phone's list of recurring charges that look like subscriptions (opened from the Overview).
/// Swipe right to confirm one, left to dismiss it; choices sync with the Mac.
struct SubscriptionsList: View {
    @Query private var transactions: [TransactionRecord]
    @Query private var accounts: [Account]
    @Query private var marks: [SubscriptionMark]
    @Environment(\.modelContext) private var context
    @State private var showDismissed = false

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    var body: some View {
        let all = SubscriptionService.detect(transactions: CashFlowScope.transactions(transactions, accounts: accounts), marks: marks)
        let totals = SubscriptionService.totals(all)
        let review = all.filter { $0.status == .unreviewed }
        let confirmed = all.filter { $0.status == .confirmed }
        let dismissed = all.filter { $0.status == .dismissed }

        List {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Per month").font(.caption).foregroundStyle(.secondary)
                        Text(money(totals.monthly)).font(.title3.bold().monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Per year").font(.caption).foregroundStyle(.secondary)
                        Text(money(totals.annual)).font(.title3.bold().monospacedDigit())
                    }
                }
            } footer: {
                Text("Same merchant, similar amount, regular schedule. Swipe right to confirm, left if it isn't a subscription.")
            }
            if all.isEmpty {
                Text("No recurring charges found yet.").foregroundStyle(.secondary)
            }
            if !review.isEmpty {
                Section("To review") { ForEach(review) { row($0) } }
            }
            if !confirmed.isEmpty {
                Section("Confirmed") { ForEach(confirmed) { row($0) } }
            }
            if !dismissed.isEmpty {
                Section {
                    if showDismissed { ForEach(dismissed) { row($0) } }
                } header: {
                    Button { showDismissed.toggle() } label: {
                        Label("Not subscriptions (\(dismissed.count))", systemImage: showDismissed ? "chevron.down" : "chevron.right")
                    }
                    .font(.footnote)
                }
            }
        }
        .navigationTitle("Subscriptions")
    }

    private func row(_ s: DetectedSubscription) -> some View {
        NavigationLink {
            SubscriptionChargesList(subscription: s,
                                    transactions: transactions.filter { s.transactionIds.contains($0.id) }.sorted { $0.date > $1.date })
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.name).foregroundStyle(s.status == .dismissed ? .secondary : .primary)
                        if s.mayHaveStopped {
                            Text("Stopped?").font(.caption2.bold()).foregroundStyle(.orange)
                        }
                    }
                    Text("\(s.cadence.label) • last \(day(s.lastCharge)) • next \(day(s.nextExpected))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text((s.isFixedAmount ? "" : "≈ ") + money(s.amount)).monospacedDigit()
                    Text("\(money(s.annualCost))/yr").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .swipeActions(edge: .leading) {
            if s.status == .confirmed {
                Button("Undo") { SubscriptionService.set(.unreviewed, for: s, in: context) }.tint(.gray)
            } else {
                Button("Confirm") { SubscriptionService.set(.confirmed, for: s, in: context) }.tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if s.status == .dismissed {
                Button("Undo") { SubscriptionService.set(.unreviewed, for: s, in: context) }.tint(.gray)
            } else {
                Button("Not one") { SubscriptionService.set(.dismissed, for: s, in: context) }.tint(.red)
            }
        }
    }
}

/// The charges behind one detected subscription.
struct SubscriptionChargesList: View {
    let subscription: DetectedSubscription
    let transactions: [TransactionRecord]

    var body: some View {
        List {
            Section {
                LabeledContent("Repeats", value: subscription.cadence.label)
                LabeledContent("Next expected", value: subscription.nextExpected.formatted(.dateTime.month(.abbreviated).day().year()))
                LabeledContent("Per month", value: currency.string(from: NSNumber(value: subscription.monthlyCost)) ?? "")
                LabeledContent("Per year", value: currency.string(from: NSNumber(value: subscription.annualCost)) ?? "")
                LabeledContent("Account", value: subscription.accountName)
            }
            Section("Charges") {
                ForEach(transactions) { t in
                    HStack {
                        Text(t.date.formatted(.dateTime.month(.abbreviated).day().year())).foregroundStyle(.secondary)
                        Spacer()
                        Text(currency.string(from: NSNumber(value: t.amount)) ?? "").monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(subscription.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
