import SwiftUI
import SwiftData

/// The phone's list of recurring charges that look like subscriptions (opened from the Overview).
/// Swipe right to confirm one, left to mark it cancelled or not a subscription; choices sync with the Mac.
struct SubscriptionsList: View {
    @Query private var transactions: [TransactionRecord]
    @Query private var marks: [SubscriptionMark]
    @Environment(\.modelContext) private var context
    @State private var showDismissed = false
    /// Group the list by card / bank account instead of by review status (saved on this phone).
    @AppStorage("subscriptions.byAccount") private var byAccount = false

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    var body: some View {
        let all = SubscriptionService.detect(transactions: transactions, marks: marks)
        let totals = SubscriptionService.totals(all)
        let review = all.filter { $0.status == .unreviewed }
        let confirmed = all.filter { $0.status == .confirmed }
        let dismissed = all.filter { $0.status == .dismissed }
        let cancelled = all.filter(\.isCancelled)
        let stillCharging = cancelled.filter(\.chargedAfterCancel)

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
                Text("Same merchant, similar amount, regular schedule. Swipe right to confirm. Swipe left when you've cancelled one, or if it isn't a subscription.")
            }
            if !stillCharging.isEmpty {
                Section {
                    ForEach(stillCharging) { row($0) }
                } header: {
                    Label("Charged after you cancelled", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } footer: {
                    Text("Check the cancellation went through, and ask for a refund.")
                }
            }
            if all.isEmpty {
                Text("No recurring charges found yet.").foregroundStyle(.secondary)
            }
            if !all.isEmpty {
                Picker("Group", selection: $byAccount) {
                    Text("By status").tag(false)
                    Text("By account").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if byAccount {
                ForEach(SubscriptionService.byAccount(review + confirmed)) { g in
                    Section {
                        ForEach(g.items) { row($0) }
                    } header: {
                        HStack {
                            Text(g.accountName)
                            Spacer()
                            Text("\(money(g.totals.monthly))/mo").monospacedDigit()
                        }
                    }
                }
            } else {
                if !review.isEmpty {
                    Section("To review") { ForEach(review) { row($0) } }
                }
                if !confirmed.isEmpty {
                    Section("Confirmed") { ForEach(confirmed) { row($0) } }
                }
            }
            if !cancelled.isEmpty {
                Section {
                    ForEach(cancelled) { row($0) }
                } header: {
                    HStack {
                        Text("Cancelled")
                        Spacer()
                        Text("Saving \(money(SubscriptionService.savings(all)))/yr").monospacedDigit().foregroundStyle(.green)
                    }
                }
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
                        if s.chargedAfterCancel {
                            Text("Charged again").font(.caption2.bold()).foregroundStyle(.red)
                        } else if s.mayHaveStopped && !s.isCancelled {
                            Text("Stopped?").font(.caption2.bold()).foregroundStyle(.orange)
                        }
                    }
                    if let c = s.cancelledAt {
                        Text(s.chargedAfterCancel
                             ? "Cancelled \(day(c)) • charged \(s.chargesSinceCancel.map(day).joined(separator: ", "))"
                             : "\(s.cadence.label) • cancelled \(day(c))")
                            .font(.caption).foregroundStyle(s.chargedAfterCancel ? .red : .secondary)
                    } else {
                        Text("\(s.cadence.label) • last \(day(s.lastCharge)) • next \(day(s.nextExpected))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !byAccount {
                        Text(s.accountName).font(.caption2).foregroundStyle(.secondary)
                    } else if s.status == .confirmed {
                        Text("Confirmed").font(.caption2).foregroundStyle(.green)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text((s.isFixedAmount ? "" : "≈ ") + money(s.amount)).monospacedDigit()
                    Text((s.isCancelled ? "saves " : "") + "\(money(s.annualCost))/yr").font(.caption2)
                        .foregroundStyle(s.isCancelled && !s.chargedAfterCancel ? .green : .secondary).monospacedDigit()
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
            if s.status == .dismissed || s.isCancelled {
                Button("Undo") { SubscriptionService.set(.unreviewed, for: s, in: context) }.tint(.gray)
            } else {
                Button("Not one") { SubscriptionService.set(.dismissed, for: s, in: context) }.tint(.red)
                Button("Cancelled") { SubscriptionService.set(.cancelled, for: s, in: context) }.tint(.orange)
            }
        }
        .contextMenu {
            if s.status != .confirmed { Button("It's a Subscription", systemImage: "checkmark.circle") { SubscriptionService.set(.confirmed, for: s, in: context) } }
            if !s.isCancelled { Button("I Cancelled It", systemImage: "nosign") { SubscriptionService.set(.cancelled, for: s, in: context) } }
            if s.status != .dismissed { Button("Not a Subscription", systemImage: "xmark.circle") { SubscriptionService.set(.dismissed, for: s, in: context) } }
            if s.status != .unreviewed { Button("Undo Choice", systemImage: "arrow.uturn.backward") { SubscriptionService.set(.unreviewed, for: s, in: context) } }
        }
    }
}

/// The charges behind one detected subscription.
struct SubscriptionChargesList: View {
    let subscription: DetectedSubscription
    let transactions: [TransactionRecord]
    @Environment(\.modelContext) private var context
    @State private var cancelDate = Date()

    var body: some View {
        List {
            Section {
                LabeledContent("Repeats", value: subscription.cadence.label)
                if !subscription.isCancelled {
                    LabeledContent("Next expected", value: subscription.nextExpected.formatted(.dateTime.month(.abbreviated).day().year()))
                }
                LabeledContent("Per month", value: currency.string(from: NSNumber(value: subscription.monthlyCost)) ?? "")
                LabeledContent("Per year", value: currency.string(from: NSNumber(value: subscription.annualCost)) ?? "")
                LabeledContent("Account", value: subscription.accountName)
            }
            if subscription.isCancelled {
                Section {
                    DatePicker("Cancelled on", selection: $cancelDate, in: ...Date(), displayedComponents: .date)
                        .onChange(of: cancelDate) { _, d in
                            guard let was = subscription.cancelledAt, !Calendar.current.isDate(was, inSameDayAs: d) else { return }
                            SubscriptionService.set(.cancelled, for: subscription, in: context, cancelledOn: d)
                        }
                    LabeledContent("Saves a year", value: currency.string(from: NSNumber(value: subscription.annualCost)) ?? "")
                } footer: {
                    if subscription.chargedAfterCancel {
                        Text("Charged again after you cancelled. Check the cancellation went through, and ask for a refund.").foregroundStyle(.red)
                    } else {
                        Text("You'll be warned here and on the list if it charges you again.")
                    }
                }
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
        .onAppear { if let c = subscription.cancelledAt { cancelDate = c } }
    }
}
