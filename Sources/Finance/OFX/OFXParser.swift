import Foundation

enum OFXParseError: Error, LocalizedError {
    case emptyData
    case noTransactionsFound
    var errorDescription: String? {
        switch self {
        case .emptyData: return "OFX data is empty."
        case .noTransactionsFound: return "No statements/transactions found in OFX file."
        }
    }
}

/// OFX parser supporting both OFX 1.x (SGML) and OFX 2.x (XML).
/// OFX 1.x: opening tags like <STMTTRN>, values run to the next '<', no closing tags.
/// OFX 2.x: proper XML with <TAG>value</TAG>.
final class OFXParser: Sendable {
    static let shared = OFXParser()
    private init() {}

    func parse(data: Data) throws -> ParsedOFXFile {
        guard !data.isEmpty else { throw OFXParseError.emptyData }
        // OFX files are usually UTF-8, sometimes windows-1252. Try UTF-8 then latin1.
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let latin = String(data: data, encoding: .isoLatin1) {
            text = latin
        } else {
            throw OFXParseError.emptyData
        }
        return try parse(string: text)
    }

    func parse(string: String) throws -> ParsedOFXFile {
        let root = buildTree(from: string)
        // OFX: outer <STMTRS> wraps inner per-account <STMTRS>. Only take nodes whose immediate child is BANKACCTFROM to avoid double-counting.
        // Bank statements are STMTRS; credit card statements are CCSTMTRS.
        let allStmts = findAll(root, name: "STMTRS") + findAll(root, name: "CCSTMTRS")
        let stmtNodes = allStmts.filter { $0.children.contains(where: { $0.tag == "BANKACCTFROM" || $0.tag == "CCACCTFROM" }) }
        let effectiveStmts = stmtNodes.isEmpty ? allStmts : stmtNodes
        var allTransactions: [OFXTransaction] = []
        var bankId = "UNKNOWN", accountId = "", accountName = "", balance: Double?
        var isCreditCard = false
        for stmt in effectiveStmts {
            let from = findFirst(stmt, name: "BANKACCTFROM") ?? findFirst(stmt, name: "CCACCTFROM") ?? stmt
            if stmt.tag == "CCSTMTRS" { isCreditCard = true }
            if let b = value(of: "BANKID", under: from) { bankId = b }
            if let a = value(of: "ACCTID", under: from) { accountId = a }
            if let n = value(of: "BRANCHID", under: from) { accountName = n }
            if let bal = value(of: "BALAMT", under: stmt) { balance = Double(bal) }
            for trn in findAll(stmt, name: "STMTTRN") {
                if let t = makeTransaction(under: trn, accountId: accountId) {
                    allTransactions.append(t)
                }
            }
        }
        // Fallback: some files use INVSTMT / INVTRAN
        if allTransactions.isEmpty {
            for stmt in findAll(root, name: "INVSTMTTRN") {
                if let t = makeTransaction(under: stmt, accountId: accountId) { allTransactions.append(t) }
            }
        }
        guard !allTransactions.isEmpty else { throw OFXParseError.noTransactionsFound }
        var seen = Set<String>()
        let deduped = allTransactions.filter { seen.insert("\($0.accountId)|\($0.fitid)").inserted }
        if accountName.isEmpty { accountName = "Account \(accountId)" }
        let fi = findFirst(root, name: "FI")
        let org = fi.flatMap { value(of: "ORG", under: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let fid = fi.flatMap { value(of: "FID", under: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        return ParsedOFXFile(bankId: bankId, accountId: accountId, accountName: accountName, balance: balance,
                             transactions: deduped, institutionOrg: org, institutionFid: fid,
                             isCreditCard: isCreditCard)
    }

    // MARK: - Tree building

    final class Node {
        let tag: String
        var value = ""
        var children: [Node] = []
        init(tag: String) { self.tag = tag.uppercased() }
    }

    private func buildTree(from string: String) -> Node {
        let root = Node(tag: "ROOT")
        var stack: [Node] = [root]
        var i = string.startIndex
        while i < string.endIndex {
            // Find next '<'
            guard let lt = string[i...].firstIndex(of: "<") else { break }
            // Text between i and lt is value of current node (for SGML)
            let textBetween = String(string[i..<lt]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !textBetween.isEmpty && textBetween != ">" {
                stack.last?.value += textBetween + " "
            }
            // Find closing '>'
            guard let gt = string[lt...].firstIndex(of: ">") else { break }
            let rawTag = String(string[string.index(after: lt)..<gt]).trimmingCharacters(in: .whitespacesAndNewlines)
            i = string.index(after: gt)

            if rawTag.hasPrefix("/") {
                // Closing tag: pop until matching.
                let tag = String(rawTag.dropFirst()).uppercased()
                while stack.count > 1 && stack.last?.tag != tag { stack.removeLast() }
                if stack.count > 1 { stack.removeLast() }
            } else if rawTag.hasPrefix("!") || rawTag.hasPrefix("?") {
                continue // comments / PIs
            } else {
                // Self-closing?
                let isSelfClosing = rawTag.hasSuffix("/")
                let tag = rawTag.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces).uppercased()
                let node = Node(tag: tag)
                stack.last?.children.append(node)
                if !isSelfClosing { stack.append(node) }
            }
        }
        return root
    }

    private func findAll(_ node: Node, name: String) -> [Node] {
        var out: [Node] = []
        if node.tag == name { out.append(node) }
        for c in node.children { out.append(contentsOf: findAll(c, name: name)) }
        return out
    }
    private func findFirst(_ node: Node, name: String) -> Node? { findAll(node, name: name).first }
    private func value(of tag: String, under node: Node) -> String? {
        findFirst(node, name: tag)?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeTransaction(under trn: Node, accountId: String) -> OFXTransaction? {
        guard let fitid = value(of: "FITID", under: trn), !fitid.isEmpty else { return nil }
        guard let amtStr = value(of: "TRNAMT", under: trn), let amt = Double(amtStr) else { return nil }
        let dateStr = value(of: "DTPOSTED", under: trn) ?? value(of: "DTUSER", under: trn) ?? value(of: "DTPOSTED", under: trn) ?? value(of: "DTSTART", under: trn) ?? "19700101"
        let name = value(of: "NAME", under: trn) ?? value(of: "MEMO", under: trn) ?? "Unknown"
        let memo = value(of: "MEMO", under: trn) ?? ""
        let trnTypeRaw = value(of: "TRNTYPE", under: trn) ?? ""
        // DEBIT/BILLPAY/etc = money out, CREDIT/DIV/INT/etc = money in; use sign as source of truth.
        let type: TransactionType = amt >= 0 ? .credit : .debit
        _ = trnTypeRaw
        return OFXTransaction(fitid: fitid, accountId: accountId, date: Self.parseOFXDate(dateStr), name: name, amount: amt, type: type, memo: memo)
    }

    static func parseOFXDate(_ s: String) -> Date {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyyMMddHHmmss.SSSZ", "yyyyMMddHHmmss.SSS", "yyyyMMddHHmmss",
            "yyyyMMddHHmm", "yyyyMMdd", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd"
        ]
        let cal = Calendar(identifier: .gregorian)
        for fmt in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d }
        }
        // OFX dates may have trailing "[tz:offset]" or "[tz:tzName]" - strip
        let stripped = trimmed.split(separator: "[").first.map(String.init) ?? trimmed
        for fmt in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            if let d = df.date(from: stripped) { return d }
        }
        return cal.date(byAdding: .day, value: -365 * 100, to: Date()) ?? Date()
    }
}

// MARK: - OFX Response request builder (for direct server sync)

struct OFXRequestBuilder {
    static func buildSignOn(profile: OFXProfile) -> String { build(profile: profile, kind: "SIGNON") }
    static func buildStatementRequest(profile: OFXProfile, since: Date = Calendar.current.date(byAdding: .day, value: -365, to: Date())!) -> String { build(profile: profile, kind: "BANK") }

    private static func build(profile: OFXProfile, kind: String) -> String {
        let date = OFXDateFormatter.string(from: Date())
        let header = """
        OFXHEADER:100
        DATA:OFXSGML
        VERSION:102
        SECURITY:NONE
        ENCODING:USASCII
        CHARSET:1252
        COMPRESSION:NONE
        OLDFILEUID:NONE
        NEWFILEUID:\(UUID().uuidString)
        """
        let body: String
        if kind == "SIGNON" {
            body = """
            <OFX>
            <SIGNONMSGSRQV1>
            <SONRQ>
            <DTCLIENT>\(date)
            <USERID>\(profile.username)
            <USERPASS>***STORED_IN_KEYCHAIN***
            <LANGUAGE>ENG
            <FI>
            <BANKID>\(profile.bankIdForRequest)
            </FI>
            <APPID>FinanceApp
            <APPVER>0001
            </SONRQ>
            </SIGNONMSGSRQV1>
            </OFX>
            """
        } else {
            body = """
            <OFX>
            <SIGNONMSGSRQV1>
            <SONRQ><DTCLIENT>\(date)</DTCLIENT></SONRQ>
            </SIGNONMSGSRQV1>
            <BANKMSGSRQV1>
            <STMTTRNRS>
            <STMTRQ>
            <BANKACCTFROM><BANKID>\(profile.bankIdForRequest)</BANKID><ACCTID>\(profile.accountId)</ACCTID><ACCTTYPE>CHECKING</ACCTTYPE></BANKACCTFROM>
            <INCTRAN><DTSTART>\(OFXDateFormatter.string(from: Calendar.current.date(byAdding: .day, value: -365, to: Date())!))</DTSTART><INCLUDEPENDING>TRUE</INCLUDEPENDING></INCTRAN>
            </STMTRQ>
            </STMTTRNRS>
            </BANKMSGSRQV1>
            </OFX>
            """
        }
        return header + "\n\n" + body
    }
}

private extension OFXProfile {
    var bankIdForRequest: String {
        // Direct OFX needs bank's OFX Bank ID. Stored in bankName for v1 demo; real apps map allowlist.
        bankName.isEmpty ? "0000" : bankName
    }
}

enum OFXDateFormatter {
    static func string(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyyMMddHHmmss"
        return df.string(from: date)
    }
}
