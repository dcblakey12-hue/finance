import SwiftUI
import SwiftData

/// Which detected subscriptions to show.
enum SubscriptionFilter: String, CaseIterable, Identifiable {
    case active = "Subscriptions", review = "To Review", confirmed = "Confirmed", dismissed = "Dismissed"
    var id: String { rawValue }
    func includes(_ s: DetectedSubscription) -> Bool {
        switch self {
        case .active: return s.status != .dismissed
        case .review: return s.status == .unreviewed
        case .confirmed: return s.status == .confirmed
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
    @State private var selection = Set<String>()
    @State private var showing: DetectedSubscription?

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day().year()) }

    var body: some View {
        let all = SubscriptionService.detect(transactions: transactions, marks: marks)
        let shown = all.filter { filter.includes($0) }
        let totals = SubscriptionService.totals(all)
        let toReview = all.filter { $0.status == .unreviewed }.count

        VStack(spacing: 0) {
            HStack(spacing: 24) {
                total("Estimated per month", money(totals.monthly))
                total("Estimated per year", money(totals.annual))
                total("Found", "\(all.filter { $0.status != .dismissed }.count)")
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(SubscriptionFilter.allCases) { f in
                        Text(f == .review && toReview > 0 ? "\(f.rawValue) (\(toReview))" : f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding()

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
                            Text("\(s.category) • \(s.accountName)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                        Text(day(s.nextExpected))
                            .foregroundStyle(s.nextExpected < Calendar.current.startOfDay(for: Date()) ? .orange : .primary)
                            .help(s.mayHaveStopped ? "No charge since it was due. It may have been cancelled." : "")
                    }.width(100)
                    TableColumn("Monthly") { s in
                        Text(money(s.monthlyCost)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(80)
                    TableColumn("Yearly") { s in
                        Text(money(s.annualCost)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(90)
                    TableColumn("") { s in
                        HStack(spacing: 4) {
                            if s.status != .confirmed {
                                Button { set(.confirmed, s) } label: { Image(systemName: "checkmark.circle") }
                                    .help("Yes, this is a subscription")
                            }
                            if s.status != .dismissed {
                                Button { set(.dismissed, s) } label: { Image(systemName: "xmark.circle") }
                                    .help("Not a subscription: hide it and leave it out of the totals")
                            }
                            if s.status != .unreviewed {
                                Button { set(.unreviewed, s) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                                    .help("Undo your choice")
                            }
                        }
                        .buttonStyle(.borderless)
                    }.width(80)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let picked = shown.filter { ids.contains($0.id) }
                    if !picked.isEmpty {
                        Button("Mark as Subscription") { picked.forEach { set(.confirmed, $0) } }
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
            Text("Found by looking for the same merchant charging a similar amount on a regular schedule. Totals leave out dismissed ones and any that seem to have stopped. Double-click a row to see its charges.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.bar)
        }
        .navigationTitle("Subscriptions")
        .sheet(item: $showing) { s in
            SubscriptionChargesSheet(subscription: s, transactions: transactions.filter { s.transactionIds.contains($0.id) })
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .active, .review: return "No recurring charges found"
        case .confirmed: return "Nothing confirmed yet"
        case .dismissed: return "Nothing dismissed"
        }
    }
    private var emptyDescription: String {
        switch filter {
        case .active, .review: return "A charge shows up here once the same merchant has billed a similar amount a few times on a regular schedule."
        case .confirmed: return "Click the check mark next to a charge to confirm it's a subscription."
        case .dismissed: return "Charges you say aren't subscriptions go here."
        }
    }

    private func set(_ status: SubscriptionStatus, _ s: DetectedSubscription) {
        SubscriptionService.set(status, for: s, in: context)
    }

    @ViewBuilder private func badge(_ s: DetectedSubscription) -> some View {
        if s.mayHaveStopped {
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

    private func total(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
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
