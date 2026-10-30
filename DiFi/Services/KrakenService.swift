import Foundation
import CryptoKit

// MARK: - Public models

struct KrakenBalance: Identifiable, Hashable {
    var id: String { rawAsset }
    let rawAsset: String       // Kraken's own code, e.g. "XXBT", "SOL", "ZEUR"
    let displayName: String    // normalized, e.g. "BTC", "SOL", "EUR"
    let amount: Double
}

struct KrakenOpenOrder: Identifiable, Hashable {
    let id: String              // order id (txid)
    let pair: String
    let type: String            // "buy" / "sell"
    let orderType: String       // "limit", "market", ...
    let price: String
    let volume: String
    let status: String
}

/// One balance movement from Kraken's Ledgers endpoint. A single trade (whether filled on the
/// order book or executed via Kraken's instant-buy widget) produces two entries sharing a
/// `refid`: a debit leg on the currency spent and a credit leg on the asset received.
struct KrakenLedgerEntry: Identifiable, Hashable {
    let id: String
    let refid: String
    let time: Date
    let type: String       // "trade", "deposit", "withdrawal", "transfer", ...
    let rawAsset: String
    let amount: Double     // signed: negative = debited, positive = credited
    let fee: Double
}

/// Remaining position for one asset after netting buys/sells with the average-cost method:
/// how much is still held, and what it cost (in EUR) to acquire the units still on hand.
struct CryptoCostBasis: Hashable {
    let amount: Double
    let costEUR: Double
    var avgPriceEUR: Double? { amount > 0 ? costEUR / amount : nil }
}

/// One individual buy or sell, derived from a matched EUR/asset ledger leg pair — the raw
/// trade-by-trade history behind a `CryptoCostBasis` total.
struct CryptoTrade: Identifiable, Hashable {
    var id: String { refid }
    let refid: String
    let time: Date
    let isBuy: Bool
    let assetAmount: Double   // always positive
    let eurAmount: Double     // always positive
    let feeEUR: Double
    var priceEUR: Double { assetAmount > 0 ? eurAmount / assetAmount : 0 }
}

enum KrakenError: LocalizedError {
    case missingCredentials
    case invalidSecret
    case api(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Add your Kraken API key and secret in Settings first."
        case .invalidSecret: return "Kraken API secret doesn't look valid (should be base64)."
        case .api(let msg): return "Kraken: \(msg)"
        case .network(let msg): return "Network error: \(msg)"
        }
    }
}

/// Thin client for the Kraken REST API — public Ticker prices and private
/// Balance / OpenOrders. Credentials are read from the Keychain, never stored
/// in SwiftData. No trading calls are made; this is read-only.
final class KrakenService {
    static let shared = KrakenService()
    private let baseURL = "https://api.kraken.com"

    // Legacy 4-letter Kraken codes that need the "Z"-fiat suffix for pair lookups
    // (e.g. XXBT trades as XXBTZEUR, not XXBTEUR).
    private let legacyPrefixed: Set<String> = ["XXBT", "XETH", "XXRP", "XXDG", "XLTC", "XXLM", "XETC", "XREP", "XZEC", "XMLN"]

    private let legacyDisplayNames: [String: String] = [
        "XXBT": "BTC", "XBT": "BTC", "XETH": "ETH", "XXRP": "XRP", "XXDG": "DOGE",
        "XLTC": "LTC", "XXLM": "XLM", "XETC": "ETC", "XREP": "REP", "XZEC": "ZEC",
        "XMLN": "MLN", "ZEUR": "EUR", "ZUSD": "USD", "ZGBP": "GBP", "ZCAD": "CAD", "ZJPY": "JPY",
    ]

    // MARK: Public API

    func fetchBalances() async throws -> [KrakenBalance] {
        let result = try await privateRequest(path: "/0/private/Balance", params: [:])
        guard let dict = result as? [String: Any] else { return [] }
        return dict.compactMap { key, value -> KrakenBalance? in
            let amount = (value as? String).flatMap(Double.init) ?? 0
            guard amount > 0 else { return nil }
            return KrakenBalance(rawAsset: key, displayName: displayName(for: key), amount: amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    func fetchOpenOrders() async throws -> [KrakenOpenOrder] {
        let result = try await privateRequest(path: "/0/private/OpenOrders", params: [:])
        guard let dict = result as? [String: Any], let open = dict["open"] as? [String: Any] else { return [] }
        return open.compactMap { txid, raw -> KrakenOpenOrder? in
            guard let order = raw as? [String: Any],
                  let descr = order["descr"] as? [String: Any] else { return nil }
            return KrakenOpenOrder(
                id: txid,
                pair: descr["pair"] as? String ?? "?",
                type: descr["type"] as? String ?? "?",
                orderType: descr["ordertype"] as? String ?? "?",
                price: descr["price"] as? String ?? "0",
                volume: order["vol"] as? String ?? "0",
                status: order["status"] as? String ?? "open"
            )
        }
    }

    /// Full ledger history (trades, deposits, withdrawals, ...), paginated 50-at-a-time. Capped at
    /// 20 pages (1000 entries) as a sane ceiling against runaway pagination. Ledgers capture every
    /// balance movement regardless of how a trade was executed — order book fill or Kraken's
    /// instant-buy widget — unlike TradesHistory, which only covers order-book fills.
    func fetchLedgers() async throws -> [KrakenLedgerEntry] {
        var allEntries: [KrakenLedgerEntry] = []
        var offset = 0
        for _ in 0..<20 {
            let result = try await privateRequest(path: "/0/private/Ledgers", params: ["ofs": String(offset)])
            guard let dict = result as? [String: Any], let ledger = dict["ledger"] as? [String: Any], !ledger.isEmpty else { break }

            for (id, raw) in ledger {
                guard let e = raw as? [String: Any],
                      let refid = e["refid"] as? String,
                      let type = e["type"] as? String,
                      let asset = e["asset"] as? String,
                      let amountStr = e["amount"] as? String, let amount = Double(amountStr),
                      let time = e["time"] as? Double else { continue }
                let fee = (e["fee"] as? String).flatMap(Double.init) ?? 0
                allEntries.append(KrakenLedgerEntry(id: id, refid: refid, time: Date(timeIntervalSince1970: time), type: type, rawAsset: asset, amount: amount, fee: fee))
            }

            let total = dict["count"] as? Int ?? allEntries.count
            offset += ledger.count
            if offset >= total { break }
        }
        return allEntries
    }

    /// Ledger entry types that represent an asset actually changing hands for currency. "trade" covers
    /// order-book fills; "spend"/"receive" cover Kraken's Instant Buy / Convert widget, which logs the
    /// two legs of a conversion under those types instead of "trade".
    private let costableLedgerTypes: Set<String> = ["trade", "spend", "receive"]

    /// Groups ledger entries into matched (EUR leg, asset leg) trade pairs, oldest first. A normal
    /// trade is exactly two legs: one EUR, one asset. Some Kraken ledger entries (multi-hop
    /// converts, rollovers) share a refid across more than two legs; blindly taking the *first*
    /// EUR/asset leg in that case can pair up amounts that don't actually belong to the same fill,
    /// so those groups are skipped rather than costed on a guess.
    private func matchedTradeLegs(fromLedger entries: [KrakenLedgerEntry]) -> [(asset: String, eurLeg: KrakenLedgerEntry, assetLeg: KrakenLedgerEntry)] {
        let groups = Dictionary(grouping: entries.filter { costableLedgerTypes.contains($0.type) }, by: \.refid)
            .values
            .sorted { ($0.first?.time ?? .distantPast) < ($1.first?.time ?? .distantPast) }

        return groups.compactMap { legs in
            guard legs.count == 2,
                  let eurLeg = legs.first(where: { displayName(for: $0.rawAsset) == "EUR" }),
                  let assetLeg = legs.first(where: { displayName(for: $0.rawAsset) != "EUR" }) else { return nil }
            return (displayName(for: assetLeg.rawAsset), eurLeg, assetLeg)
        }
    }

    /// Nets buys/sells per normalized display asset (average-cost method, oldest trades first) to
    /// find the EUR cost basis of whatever amount of each asset is still held.
    func costBasisByAsset(fromLedger entries: [KrakenLedgerEntry]) -> [String: CryptoCostBasis] {
        var amounts: [String: Double] = [:]
        var costs: [String: Double] = [:]

        for (asset, eurLeg, assetLeg) in matchedTradeLegs(fromLedger: entries) {
            // Each ledger leg's `fee` is denominated in that leg's own asset (e.g. a PEPE-leg fee
            // is paid in PEPE, not EUR) — only the EUR leg's fee belongs in the EUR cost basis.
            // Summing both legs' fees indiscriminately previously added a tiny asset-denominated
            // fee (thousands of a low-value token) straight into the EUR total.
            let totalFee = eurLeg.fee
            let amount = amounts[asset] ?? 0
            let cost = costs[asset] ?? 0

            if assetLeg.amount > 0, eurLeg.amount < 0 {
                // Buy: spent EUR, received the asset.
                amounts[asset] = amount + assetLeg.amount
                costs[asset] = cost + abs(eurLeg.amount) + totalFee
            } else if assetLeg.amount < 0, eurLeg.amount > 0 {
                // Sell: gave up the asset, received EUR.
                let avgCost = amount > 0 ? cost / amount : 0
                let sold = abs(assetLeg.amount)
                amounts[asset] = max(0, amount - sold)
                costs[asset] = max(0, cost - avgCost * sold)
            }
        }

        return amounts.keys.reduce(into: [:]) { result, asset in
            result[asset] = CryptoCostBasis(amount: amounts[asset] ?? 0, costEUR: costs[asset] ?? 0)
        }
    }

    /// Individual buy/sell history per normalized display asset, newest first — the trade-by-trade
    /// detail behind `costBasisByAsset`'s running totals.
    func tradeHistoryByAsset(fromLedger entries: [KrakenLedgerEntry]) -> [String: [CryptoTrade]] {
        var trades: [String: [CryptoTrade]] = [:]

        for (asset, eurLeg, assetLeg) in matchedTradeLegs(fromLedger: entries) {
            guard assetLeg.amount != 0, eurLeg.amount != 0, (assetLeg.amount > 0) != (eurLeg.amount > 0) else { continue }
            let trade = CryptoTrade(
                refid: assetLeg.refid,
                time: assetLeg.time,
                isBuy: assetLeg.amount > 0,
                assetAmount: abs(assetLeg.amount),
                eurAmount: abs(eurLeg.amount),
                feeEUR: eurLeg.fee
            )
            trades[asset, default: []].append(trade)
        }

        return trades.mapValues { $0.sorted { $0.time > $1.time } }
    }

    /// EUR price for each raw Kraken asset code, e.g. ["XXBT": 56190.0, "SOL": 143.2].
    /// Pairs are resolved against Kraken's AssetPairs list first, because a single unknown pair in a
    /// Ticker request fails the whole request ("EQuery:Unknown asset pair"). Assets with no EUR pair
    /// but a USD pair (e.g. USDG) are priced via USD and converted with the EUR/USD rate.
    /// Best-effort: assets with neither pair (delisted / exotic) are omitted.
    func fetchPricesEUR(for rawAssets: [String]) async throws -> [String: Double] {
        let assets = rawAssets.filter { displayName(for: $0) != "EUR" }
        guard !assets.isEmpty else { return [:] }

        let pairIndex = try await fetchAssetPairIndex()
        let eurUsdPair = pairIndex[PairKey(base: "ZEUR", quote: "ZUSD")]

        // For each asset: (pair to query, whether its price is quoted in USD and needs converting).
        var lookups: [String: (pair: String, inUSD: Bool)] = [:]
        for asset in assets {
            let candidates = baseCandidates(for: asset)
            if let pair = candidates.lazy.compactMap({ pairIndex[PairKey(base: $0, quote: "ZEUR")] }).first {
                lookups[asset] = (pair, false)
            } else if eurUsdPair != nil,
                      let pair = candidates.lazy.compactMap({ pairIndex[PairKey(base: $0, quote: "ZUSD")] }).first {
                lookups[asset] = (pair, true)
            }
        }

        var pairsToQuery = Set(lookups.values.map(\.pair))
        if lookups.values.contains(where: \.inUSD) || assets.contains(where: { displayName(for: $0) == "USD" }),
           let eurUsdPair {
            pairsToQuery.insert(eurUsdPair)
        }
        guard !pairsToQuery.isEmpty else { return [:] }

        let lastPrices = try await fetchTickerLastPrices(pairs: Array(pairsToQuery))
        let eurUsd = eurUsdPair.flatMap { lastPrices[$0] }

        var prices: [String: Double] = [:]
        for asset in assets {
            if displayName(for: asset) == "USD" {
                if let eurUsd, eurUsd > 0 { prices[asset] = 1 / eurUsd }
                continue
            }
            guard let lookup = lookups[asset], let price = lastPrices[lookup.pair] else { continue }
            if lookup.inUSD {
                guard let eurUsd, eurUsd > 0 else { continue }
                prices[asset] = price / eurUsd
            } else {
                prices[asset] = price
            }
        }
        return prices
    }

    private struct PairKey: Hashable {
        let base: String
        let quote: String
    }

    /// Kraken's tradable pairs keyed by (base, quote) asset code → the pair's canonical key,
    /// which is also the key Ticker results come back under. Cached after the first load.
    private var cachedPairIndex: [PairKey: String]?

    private func fetchAssetPairIndex() async throws -> [PairKey: String] {
        if let cachedPairIndex { return cachedPairIndex }

        let (data, response) = try await URLSession.shared.data(from: URL(string: baseURL + "/0/public/AssetPairs")!)
        try validate(response: response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let errors = json["error"] as? [String], !errors.isEmpty {
            throw KrakenError.api(errors.joined(separator: ", "))
        }
        guard let result = json["result"] as? [String: Any] else { return [:] }

        var index: [PairKey: String] = [:]
        for (key, raw) in result {
            guard let info = raw as? [String: Any],
                  let base = info["base"] as? String, let quote = info["quote"] as? String else { continue }
            if let status = info["status"] as? String, status != "online" { continue }
            // Skip dark-pool duplicates (".d"), which share base/quote with the real pair.
            if key.hasSuffix(".d") { continue }
            index[PairKey(base: base, quote: quote)] = key
        }
        cachedPairIndex = index
        return index
    }

    private func fetchTickerLastPrices(pairs: [String]) async throws -> [String: Double] {
        var components = URLComponents(string: baseURL + "/0/public/Ticker")!
        components.queryItems = [URLQueryItem(name: "pair", value: pairs.joined(separator: ","))]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let errors = json["error"] as? [String], !errors.isEmpty {
            throw KrakenError.api(errors.joined(separator: ", "))
        }
        guard let result = json["result"] as? [String: Any] else { return [:] }

        var prices: [String: Double] = [:]
        for (pair, raw) in result {
            guard let ticker = raw as? [String: Any],
                  let close = ticker["c"] as? [String], let price = close.first.flatMap(Double.init) else { continue }
            prices[pair] = price
        }
        return prices
    }

    /// Asset codes a balance might appear under as a pair's base, e.g. "XBT.M" → ["XBT.M", "XBT", "XXBT"].
    private func baseCandidates(for rawAsset: String) -> [String] {
        var candidates = [rawAsset]
        if let dot = rawAsset.firstIndex(of: ".") {
            candidates.append(String(rawAsset[..<dot]))
        }
        let stripped = candidates.last!
        candidates.append("X" + stripped)
        if let legacy = legacyDisplayNames.first(where: { $0.value == displayName(for: rawAsset) && legacyPrefixed.contains($0.key) })?.key {
            candidates.append(legacy)
        }
        return candidates
    }

    // MARK: Symbol helpers

    private func displayName(for rawAsset: String) -> String {
        if let mapped = legacyDisplayNames[rawAsset] { return mapped }
        // Strip Kraken staking suffixes like ".S" / ".M" / ".B" for a clean display name.
        if let dot = rawAsset.firstIndex(of: ".") { return String(rawAsset[..<dot]) }
        return rawAsset
    }

    // MARK: Signed private requests

    private func privateRequest(path: String, params: [String: String]) async throws -> Any {
        guard let apiKey = KeychainHelper.read(account: KrakenCredentialKey.apiKey), !apiKey.isEmpty,
              let apiSecret = KeychainHelper.read(account: KrakenCredentialKey.apiSecret), !apiSecret.isEmpty else {
            throw KrakenError.missingCredentials
        }

        let nonce = String(Int(Date().timeIntervalSince1970 * 1000))
        var postParams = params
        postParams["nonce"] = nonce
        let postData = postParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")

        guard let signature = sign(path: path, nonce: nonce, postData: postData, secretBase64: apiSecret) else {
            throw KrakenError.invalidSecret
        }

        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.httpBody = postData.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "API-Key")
        request.setValue(signature, forHTTPHeaderField: "API-Sign")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let errors = json["error"] as? [String], !errors.isEmpty {
            throw KrakenError.api(errors.joined(separator: ", "))
        }
        return json["result"] ?? [:]
    }

    /// Kraken's private-endpoint signature: HMAC-SHA512(path + SHA256(nonce + postData), base64-decoded secret).
    private func sign(path: String, nonce: String, postData: String, secretBase64: String) -> String? {
        guard let secretData = Data(base64Encoded: secretBase64) else { return nil }

        let noncePostData = Data((nonce + postData).utf8)
        let sha256Digest = SHA256.hash(data: noncePostData)

        var message = Data(path.utf8)
        message.append(contentsOf: sha256Digest)

        let key = SymmetricKey(data: secretData)
        let hmac = HMAC<SHA512>.authenticationCode(for: message, using: key)
        return Data(hmac).base64EncodedString()
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw KrakenError.network("HTTP \(code)")
        }
    }
}
