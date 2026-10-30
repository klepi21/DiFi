import Foundation

/// One ERC-20 (or native ETH) balance held by a watched wallet address, valued in EUR.
struct WalletTokenHolding: Identifiable, Hashable {
    var id: String { contractAddress ?? "ETH" }
    let symbol: String
    let contractAddress: String?   // nil for native ETH
    let amount: Double
    let priceEUR: Double
    let priceUSD: Double
    var valueEUR: Double { amount * priceEUR }
    var valueUSD: Double { amount * priceUSD }
}

/// Result of one wallet sync pass. CoinGecko's key-less API is rate-limited enough that a single
/// token's price can fail to load on any given pass — `holdings` alone can't tell a token that
/// genuinely dropped below the threshold apart from one that simply couldn't be priced this
/// round, so callers get both pieces: what's confirmed now, and what's still on-chain but
/// unpriced (a caller with its own cache should leave those alone rather than delete them).
struct WalletSyncResult {
    let holdings: [WalletTokenHolding]      // priced this round and above the threshold
    let onChainContracts: Set<String>       // every ERC-20 contract currently held (lowercased), regardless of pricing outcome
    let pricedContracts: Set<String>        // subset of onChainContracts CoinGecko actually returned a price for this round
    let hasEthBalance: Bool                 // on-chain ETH balance > 0, regardless of pricing outcome
    let ethPriced: Bool                     // whether the ETH price fetch succeeded this round
}

/// UserDefaults key for the watched wallet address (public data, so not kept in the Keychain).
enum WalletSettingsKey {
    static let address = "wallet.address"
}

enum EthWalletError: LocalizedError {
    case api(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .api(let msg): return "Blockscout: \(msg)"
        case .network(let msg): return "Network error: \(msg)"
        }
    }
}

/// Read-only client for watching a non-custodial ERC-20 wallet — no private keys, no signing,
/// just public on-chain data. Token holdings come from Blockscout's free Etherscan-compatible API
/// (no API key required); USD/EUR pricing comes from CoinGecko's free contract-address lookup.
final class EthWalletService {
    static let shared = EthWalletService()
    private let blockscoutBaseURL = "https://eth.blockscout.com/api"
    private let coingeckoBaseURL = "https://api.coingecko.com/api/v3"

    /// Every ERC-20 + native ETH balance for `address` worth more than `minUSD` (default $1),
    /// sorted by EUR value descending, plus enough bookkeeping (see `WalletSyncResult`) for a
    /// caller to tell "priced below threshold" apart from "couldn't price this round".
    func fetchHoldings(address: String, minUSD: Double = 1.0) async throws -> WalletSyncResult {
        async let tokenListTask = fetchTokenList(address: address)
        async let ethBalanceTask = fetchEthBalance(address: address)
        let (tokens, ethBalanceWei) = try await (tokenListTask, ethBalanceTask)

        let contractAddresses = Array(Set(tokens.map(\.contractAddress)))
        let prices = try await fetchPrices(contractAddresses: contractAddresses)
        let ethPrice = await fetchEthPrice()

        var holdings: [WalletTokenHolding] = []

        let ethAmount = ethBalanceWei / pow(10, 18)
        let ethPriced = ethPrice.usd > 0
        if ethPriced, ethAmount * ethPrice.usd > minUSD {
            holdings.append(WalletTokenHolding(symbol: "ETH", contractAddress: nil, amount: ethAmount, priceEUR: ethPrice.eur, priceUSD: ethPrice.usd))
        }

        for token in tokens {
            guard let price = prices[token.contractAddress.lowercased()] else { continue }
            let amount = token.rawBalance / pow(10, token.decimals)
            guard amount * price.usd > minUSD else { continue }
            holdings.append(WalletTokenHolding(symbol: token.symbol, contractAddress: token.contractAddress, amount: amount, priceEUR: price.eur, priceUSD: price.usd))
        }

        return WalletSyncResult(
            holdings: holdings.sorted { $0.valueEUR > $1.valueEUR },
            onChainContracts: Set(tokens.map { $0.contractAddress.lowercased() }),
            pricedContracts: Set(prices.keys),
            hasEthBalance: ethBalanceWei > 0,
            ethPriced: ethPriced
        )
    }

    // MARK: Blockscout

    private struct RawToken {
        let contractAddress: String
        let symbol: String
        let decimals: Double
        let rawBalance: Double
    }

    private func fetchTokenList(address: String) async throws -> [RawToken] {
        var components = URLComponents(string: blockscoutBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: "tokenlist"),
            URLQueryItem(name: "address", value: address),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let result = json["result"] as? [[String: Any]] else { return [] }

        return result.compactMap { entry -> RawToken? in
            guard let contractAddress = entry["contractAddress"] as? String,
                  let symbol = entry["symbol"] as? String,
                  let decimalsStr = entry["decimals"] as? String, let decimals = Double(decimalsStr),
                  let balanceStr = entry["balance"] as? String, let rawBalance = Double(balanceStr),
                  (entry["type"] as? String) == "ERC-20" else { return nil }
            return RawToken(contractAddress: contractAddress, symbol: symbol, decimals: decimals, rawBalance: rawBalance)
        }
    }

    private func fetchEthBalance(address: String) async throws -> Double {
        var components = URLComponents(string: blockscoutBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: "balance"),
            URLQueryItem(name: "address", value: address),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let result = json["result"] as? String, let wei = Double(result) else { return 0 }
        return wei
    }

    // MARK: CoinGecko

    private struct Price { let usd: Double; let eur: Double }

    private func fetchPrices(contractAddresses: [String]) async throws -> [String: Price] {
        // CoinGecko's key-less API caps this endpoint at one contract address per request (no
        // batching), so each token is priced individually. A per-token failure (unlisted token,
        // transient rate limit) just drops that one token rather than failing the whole sync.
        var prices: [String: Price] = [:]
        for contractAddress in contractAddresses {
            var components = URLComponents(string: coingeckoBaseURL + "/simple/token_price/ethereum")!
            components.queryItems = [
                URLQueryItem(name: "contract_addresses", value: contractAddress),
                URLQueryItem(name: "vs_currencies", value: "usd,eur"),
            ]
            guard let (data, response) = try? await URLSession.shared.data(from: components.url!),
                  (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { continue }

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
            if let entry = json?[contractAddress] ?? json?[contractAddress.lowercased()],
               let usd = entry["usd"] as? Double {
                prices[contractAddress.lowercased()] = Price(usd: usd, eur: entry["eur"] as? Double ?? usd)
            }
        }
        return prices
    }

    /// Best-effort: a CoinGecko hiccup here shouldn't blow up the whole wallet sync — it just
    /// means the ETH balance can't be valued (and so won't clear the $1 filter) this round.
    private func fetchEthPrice() async -> Price {
        var components = URLComponents(string: coingeckoBaseURL + "/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: "ethereum"),
            URLQueryItem(name: "vs_currencies", value: "usd,eur"),
        ]
        guard let (data, response) = try? await URLSession.shared.data(from: components.url!),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return Price(usd: 0, eur: 0) }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Double]] ?? [:]
        guard let entry = json["ethereum"], let usd = entry["usd"] else { return Price(usd: 0, eur: 0) }
        return Price(usd: usd, eur: entry["eur"] ?? usd)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw EthWalletError.network("HTTP \(http.statusCode)")
        }
    }
}
