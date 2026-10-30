import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsQuery: [AppSettings]
    @Query private var incomes: [IncomeEntry]

    @State private var efka: String = ""
    @State private var loaded = false

    @State private var krakenApiKey: String = ""
    @State private var krakenApiSecret: String = ""
    @State private var krakenSaved = false

    @AppStorage(WalletSettingsKey.address) private var walletAddress: String = ""

    /// Safe accessor: returns the existing singleton or creates it if missing.
    /// (The DiFiApp init also seeds this, but this is a belt-and-suspenders guard.)
    private var settings: AppSettings {
        if let s = settingsQuery.first { return s }
        let s = AppSettings()
        context.insert(s)
        try? context.save()
        return s
    }

    // Live projected tax-reserve rate — extrapolates this year's income pace through the
    // real progressive brackets. Recalculates automatically every time income is added.
    private var projectedRatePct: Double {
        projectedTaxReservePct(incomes: incomes, efkaMonthly: settings.efkaMonthly)
    }

    var body: some View {
        Form {
            Section("Greek Freelancer Tax Settings") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tax Reserve Rate (live)")
                        Spacer()
                        Text("\(String(format: "%.1f", projectedRatePct))%")
                            .font(.headline)
                            .foregroundStyle(.purple)
                    }
                    Text("Calculated automatically from your income pace this year through the progressive freelancer tax brackets — no need to set it manually. It updates every time you add income and becomes more accurate as the year progresses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("ΕΦΚΑ Monthly (€)")
                    Spacer()
                    TextField("0", text: $efka)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit { saveEfka() }
                        .onChange(of: efka) { _, _ in saveEfka() }
                }
                Text("ΕΦΚΑ is deducted from gross income before calculating net. Set your actual monthly ΕΦΚΑ contribution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Kraken API") {
                SecureField("API Key", text: $krakenApiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Secret", text: $krakenApiSecret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { saveKrakenCredentials() }
                        .buttonStyle(.borderedProminent)
                        .disabled(krakenApiKey.isEmpty || krakenApiSecret.isEmpty)
                    if krakenSaved {
                        Text("Saved").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { removeKrakenCredentials() }
                }
                Text("Create a Kraken API key with \"Query Funds\" and \"Query Open Orders\" permissions only — never grant Withdraw or Trade. Stored in the macOS Keychain, never in the app's database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ethereum Wallet (read-only)") {
                TextField("0x…", text: $walletAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Public address only — no private keys. ETH and ERC-20 balances worth more than $1 are shown on the Crypto tab. Leave empty to disable wallet sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Tax Rate") { Text("Προκαταβολή φόρου εισοδήματος") }
                LabeledContent("Social Insurance") { Text("ΕΦΚΑ — Ενιαίος Φορέας Κοινωνικής Ασφάλισης") }
                LabeledContent("Tax Office") { Text("ΔΟΥ — Δημόσια Οικονομική Υπηρεσία") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            guard !loaded else { return }
            efka = settings.efkaMonthly == 0 ? "" : String(format: "%.2f", settings.efkaMonthly)
            krakenApiKey = KeychainHelper.read(account: KrakenCredentialKey.apiKey) ?? ""
            krakenApiSecret = KeychainHelper.read(account: KrakenCredentialKey.apiSecret) ?? ""
            loaded = true
        }
    }

    private func saveEfka() {
        let v = Double(efka.replacingOccurrences(of: ",", with: ".")) ?? 0
        settings.efkaMonthly = v
        try? context.save()
    }

    private func saveKrakenCredentials() {
        KeychainHelper.save(krakenApiKey, account: KrakenCredentialKey.apiKey)
        KeychainHelper.save(krakenApiSecret, account: KrakenCredentialKey.apiSecret)
        krakenSaved = true
    }

    private func removeKrakenCredentials() {
        KeychainHelper.delete(account: KrakenCredentialKey.apiKey)
        KeychainHelper.delete(account: KrakenCredentialKey.apiSecret)
        krakenApiKey = ""
        krakenApiSecret = ""
        krakenSaved = false
    }
}
