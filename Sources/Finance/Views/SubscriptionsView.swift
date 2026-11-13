import SwiftUI
import SwiftData

/// Which detected subscriptions to show.
enum SubscriptionFilter: String, CaseIterable, Identifiable {
    case active = "Subscriptions", review = "To Review", confirmed = "Confirmed", cancelled = "Cancelled", dismissed = "Dismissed"
    var id: String { rawValue }
    func includes(_ s: DetectedSubscription) -> Bool {
        switch self {
        case .active: return s.status == .unreviewed || s.status == .confirmed || s.chargedAfterCancel
        case .review: return s.status == .unreviewed
        case .confirmed: return s.status == .confirmed
        case .cancelled: return s.status == .cancelled
        case .dismissed: return s.status == .dismissed
        }
    }
}

/// Sidebar section: recurring charges found in your transactions that look like subscriptions.
struct SubscriptionsView: View {
    @Query private var transactions: [TransactionRecord]
    @Query private var marks: [SubscriptionMark]
    @Environment(\.modelContext) private var context
    @State private var filter: SubscriptionFilter = .active
    /// Show one account's subscriptions (OFX accountId); nil = every account.
    @State private var accountFilter: String?
    @State private var selection = Set<String>()
    @State private var showing: DetectedSubscription?
    /// Picking the day a subscription was cancelled.
    @State private var cancelling: DetectedSubscription?

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day().year()) }

    var body: some View {
        let all = SubscriptionService.detect(transactions: transactions, marks: marks)
        let listed = all.filter { filter.includes($0) }
        let groups = SubscriptionService.byAccount(listed)
        let shown = listed.filter { accountFilter == nil || $0.accountId == accountFilter }
        let totals = SubscriptionService.totals(all)
        let toReview = all.filter { $0.status == .unreviewed }.count
        let savings = SubscriptionService.savings(all)
        let stillCharging = all.filter(\.chargedAfterCancel)

        VStack(spacing: 0) {
            HStack(spacing: 24) {
                total("Estimated per month", money(totals.monthly))
                total("Estimated per year", money(totals.annual))
                total("Found", "\(all.filter { $0.status == .unreviewed || $0.status == .confirmed }.count)")
                if savings > 0 { total("Saved by cancelling", "\(money(savings))/yr", .green) }
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(SubscriptionFilter.allCases) { f in
                        Text(f == .review && toReview > 0 ? "\(f.rawValue) (\(toReview))" : f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding()

            if !stillCharging.isEmpty {
                Label("Still charging after you cancelled: " + stillCharging.map { "\($0.name) (\(day($0.chargesSinceCancel.last!)))" }.joined(separator: ", ")
                      + ". Check the cancellation went through, and ask for a refund.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal).padding(.bottom, 8)
            }

            if groups.count > 1 || accountFilter != nil { accountStrip(groups, total: listed) }

            if shown.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "repeat.circle",
                                       description: Text(emptyDescription))
            } else {
                Table(shown, selection: $selection) {
                    TableColumn("Merchant") { s in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(s.name).foregroundStyle(s.status == .dismissed ? .secondary : .primary)
                                badge(s)
                            }
                            Text(s.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Account") { s in Text(s.accountName) }.width(min: 110, ideal: 150)
                    TableColumn("Repeats") { s in
                        Text("\(s.cadence.label) • \(s.chargeCount) charges").foregroundStyle(.secondary)
                    }.width(min: 120, ideal: 160)
                    TableColumn("Amount") { s in
                        Text((s.isFixedAmount ? "" : "≈ ") + money(s.amount))
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .help(s.isFixedAmount ? "The same every time" : "The amount varies; this is the latest charge")
                    }.width(90)
                    TableColumn("Last charge") { s in Text(day(s.lastCharge)) }.width(100)
                    TableColumn("Next expected") { s in
                        if let c = s.cancelledAt {
                            Text("Cancelled \(day(c))").foregroundStyle(s.chargedAfterCancel ? .red : .secondary)
                                .help(s.chargedAfterCancel ? "Charged again on \(s.chargesSinceCancel.map(day).joined(separator: ", ")), after you cancelled" : "No charges since you cancelled")
                        } else {
                            Text(day(s.nextExpected))
                                .foregroundStyle(s.nextExpected < Calendar.current.startOfDay(for: Date()) ? .orange : .primary)
                                .help(s.mayHaveStopped ? "No charge since it was due. If you cancelled it, mark it Cancelled." : "")
                        }
                    }.width(min: 100, ideal: 130)
                    TableColumn("Monthly") { s in
                        Text(money(s.monthlyCost)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(80)
                    TableColumn("Yearly") { s in
                        Text(money(s.annualCost)).monospacedDigit()
                            .foregroundStyle(s.isCancelled && !s.chargedAfterCancel ? .green : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help(s.chargedAfterCancel ? "Still charging you after you cancelled" : (s.isCancelled ? "What cancelling it saves you a year" : ""))
                    }.width(90)
                    TableColumn("") { s in
                        HStack(spacing: 4) {
                            if s.status != .confirmed {
                                Button { set(.confirmed, s) } label: { Image(systemName: "checkmark.circle") }
                                    .help("Yes, this is a subscription")
                            }
                            if s.status != .cancelled {
                                Button { cancelling = s } label: { Image(systemName: "nosign") }
                                    .help("I cancelled it: move it to Cancelled and count what it saves")
                            }
                            if s.status != .dismissed && s.status != .cancelled {
                                Button { set(.dismissed, s) } label: { Image(systemName: "xmark.circle") }
                                    .help("Not a subscription: hide it and leave it out of the totals")
                            }
                            if s.status != .unreviewed {
                                Button { set(.unreviewed, s) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                                    .help("Undo your choice")
                            }
                        }
                        .buttonStyle(.borderless)
                    }.width(100)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let picked = shown.filter { ids.contains($0.id) }
                    if !picked.isEmpty {
                        Button("Mark as Subscription") { picked.forEach { set(.confirmed, $0) } }
                        Button("I Cancelled It") { picked.forEach { set(.cancelled, $0) } }
                        if picked.count == 1, let s = picked.first {
                            Button(s.isCancelled ? "Change Cancel Date…" : "I Cancelled It On…") { cancelling = s }
                        }
                        Button("Not a Subscription") { picked.forEach { set(.dismissed, $0) } }
                        Button("Undo Choice") { picked.forEach { set(.unreviewed, $0) } }
                        if picked.count == 1, let s = picked.first {
                            Divider()
                            Button("Show Charges…") { showing = s }
                        }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let s = shown.first(where: { ids.contains($0.id) }) { showing = s }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Found by looking for the same merchant charging a similar amount on a regular schedule. Totals leave out cancelled and dismissed ones, and any that seem to have stopped (a cancelled one that still charges you stays in). Cancelled ones are watched: if they charge you again you'll see a warning. Double-click a row to see its charges.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.bar)
        }
        .navigationTitle("Subscriptions")
        .sheet(item: $cancelling) { s in
            CancelSubscriptionSheet(subscription: s) { date in
                SubscriptionService.set(.cancelled, for: s, in: context, cancelledOn: date)
                cancelling = nil
            } onCancel: { cancelling = nil }
        }
        .sheet(item: $showing) { s in
            SubscriptionChargesSheet(subscription: s, transactions: transactions.filter { s.transactionIds.contains($0.id) })
        }
    }

    /// One button per card or bank account with what its subscriptions cost; click to show only that account.
    private func accountStrip(_ groups: [SubscriptionService.AccountGroup], total: [DetectedSubscription]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All accounts", count: total.count, monthly: SubscriptionService.totals(total).monthly, selected: accountFilter == nil) {
                    accountFilter = nil
                }
                ForEach(groups) { g in
                    chip(g.accountName, count: g.items.count, monthly: g.totals.monthly, selected: accountFilter == g.accountId) {
                        accountFilter = accountFilter == g.accountId ? nil : g.accountId
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, count: Int, monthly: Double, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(count) • \(money(monthly))/mo").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        .help("Show only the subscriptions charged to \(title)")
    }

    private var emptyTitle: String {
        switch filter {
        case .active, .review: return "No recurring charges found"
        case .confirmed: return "Nothing confirmed yet"
        case .cancelled: return "Nothing cancelled"
        case .dismissed: return "Nothing dismissed"
        }
    }
    private var emptyDescription: String {
        switch filter {
        case .active, .review: return "A charge shows up here once the same merchant has billed a similar amount a few times on a regular schedule."
        case .confirmed: return "Click the check mark next to a charge to confirm it's a subscription."
        case .cancelled: return "When you cancel a subscription, click the ⊘ button next to it. It moves here, leaves the totals, and you'll be warned if it charges you again."
        case .dismissed: return "Charges you say aren't subscriptions go here."
        }
    }

    private func set(_ status: SubscriptionStatus, _ s: DetectedSubscription) {
        SubscriptionService.set(status, for: s, in: context)
    }

    @ViewBuilder private func badge(_ s: DetectedSubscription) -> some View {
        if s.chargedAfterCancel {
            tag("Charged after cancel", .red)
        } else if s.isCancelled {
            tag("Cancelled", .gray)
        } else if s.mayHaveStopped {
            tag("Stopped?", .orange)
        } else if s.status == .confirmed {
            tag("Confirmed", .green)
        } else if s.status == .unreviewed {
            tag("New", .blue)
        }
    }
    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }

    private func total(_ title: String, _ value: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
        }
    }
}

/// Mark a subscription cancelled, on the day you cancelled it.
struct CancelSubscriptionSheet: View {
    let subscription: DetectedSubscription
    let onSave: (Date) -> Void
    let onCancel: () -> Void
    @State private var date: Date

    init(subscription: DetectedSubscription, onSave: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.subscription = subscription; self.onSave = onSave; self.onCancel = onCancel
        _date = State(initialValue: subscription.cancelledAt ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cancelled \(subscription.name)").font(.headline)
            Text("It leaves your totals and counts as saving \(currency.string(from: NSNumber(value: subscription.annualCost)) ?? "") a year. If a charge still comes through after this day, Finance will warn you.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DatePicker("Cancelled on", selection: $date, in: ...Date(), displayedComponents: .date)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Mark Cancelled") { onSave(date) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

/// The charges behind one detected subscription, newest first.
struct SubscriptionChargesSheet: View {
    let subscription: DetectedSubscription
    let transactions: [TransactionRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(subscription.name).font(.title2.bold())
            Text("\(subscription.cadence.label) • about \(currency.string(from: NSNumber(value: subscription.annualCost)) ?? "") a year")
                .foregroundStyle(.secondary)
            Table(transactions.sorted { $0.date > $1.date }) {
                TableColumn("Date") { t in Text(t.date.formatted(.dateTime.month(.abbreviated).day().year())) }.width(110)
                TableColumn("Description") { t in Text(t.name) }
                TableColumn("Account") { t in Text(t.accountName).foregroundStyle(.secondary) }
                TableColumn("Amount") { t in
                    Text(currency.string(from: NSNumber(value: t.amount)) ?? "").monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(90)
            }
            .frame(minHeight: 220)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
    }
}
