import SwiftUI

/// What the last bank sync brought down, bank by bank.
struct PlaidSyncReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reports = PlaidSyncReport.all()

    var body: some View {
        NavigationStack {
            Group {
                if reports.isEmpty {
                    ContentUnavailableView("No bank sync yet", systemImage: "arrow.triangle.2.circlepath",
                                           description: Text("After you click Sync, this shows what each bank sent: new, pending, matched and removed transactions."))
                } else {
                    List {
                        ForEach(reports) { r in report(r) }
                    }
                }
            }
            .navigationTitle("Last Bank Sync")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    @ViewBuilder private func report(_ r: PlaidSyncReport) -> some View {
        Section {
            if let e = r.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if r.isEmpty && r.error == nil { Text("Nothing new.").foregroundStyle(.secondary) }
            group("Matched to entries you typed in — now reconciled", r.matchedToYours, "checkmark.circle.fill", .green)
            group("Pending at the bank, same as an entry you typed in — stays outstanding until it posts", r.pendingMatchedToYours, "clock", .blue)
            group("Pending at the bank — not in the balance until it posts", r.pending, "clock", .blue)
            group("Pending, now posted", r.pendingPosted, "checkmark.circle", .green)
            group("New", r.added, "plus.circle", .accentColor)
            group("Matched to transactions imported from a bank file", r.matchedToFiles, "link", .secondary)
            group("Changed by the bank", r.updated, "pencil.circle", .orange)
            group("Removed by the bank", r.removed, "minus.circle", .red)
            if r.alreadyHad > 0 {
                Text("\(r.alreadyHad) transaction\(r.alreadyHad == 1 ? " was" : "s were") already here, so nothing changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(r.institution).font(.headline)
                Spacer()
                Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ lines: [PlaidSyncReport.Line], _ symbol: String, _ color: Color) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(title) (\(lines.count))", systemImage: symbol).font(.subheadline.bold()).foregroundStyle(color)
                ForEach(lines) { l in
                    HStack(alignment: .firstTextBaseline) {
                        Text(l.date.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.name)
                            Text([l.account, l.note].compactMap { $0 }.joined(separator: " • ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(currency.string(from: NSNumber(value: l.amount)) ?? "").monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
