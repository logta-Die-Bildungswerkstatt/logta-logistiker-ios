//
//  IAPBridge.swift
//  LogTa Logistiker
//
//  WICHTIG: Diese Datei ersetzt den alten Ansatz (Storyboard-Manipulation).
//  Statt die Main.storyboard blind per Skript zu ändern (riskant, Fehler
//  zeigen sich erst beim Kunden als schwarzer Bildschirm), hängt sich diese
//  Datei sauber von AUSSEN an die bereits fertig geladene App an.
//
//  Die Storyboard-Datei und die Standard-Capacitor-Klassen bleiben
//  UNVERÄNDERT. Dadurch kann dieser Ansatz die App nicht mehr "zerstören" -
//  im schlimmsten Fall funktioniert nur der Kauf nicht, aber die App selbst
//  startet garantiert normal.
//

import Foundation
import WebKit
import StoreKit
import Capacitor

final class IAPBridge: NSObject, WKScriptMessageHandler {

    static let shared = IAPBridge()

    // Muss exakt mit IAP_PRODUCT_ID in der HTML/JS-Datei übereinstimmen
    private let productId = "com.logta.logistiker.fullversion"

    private weak var attachedWebView: WKWebView?
    private var isListening = false

    private override init() {
        super.init()
    }

    // MARK: - Andocken an die WebView (kann mehrfach sicher aufgerufen werden)

    func attach(to webView: WKWebView) {
        // Bereits an genau diese WebView angehängt? Dann nichts tun.
        if attachedWebView === webView {
            return
        }

        // Falls vorher an eine andere WebView angehängt: sauber lösen,
        // damit wir nie zweimal denselben Handler-Namen registrieren
        // (das würde sonst zum Absturz führen).
        if let old = attachedWebView {
            old.configuration.userContentController.removeScriptMessageHandler(forName: "iapPurchase")
            old.configuration.userContentController.removeScriptMessageHandler(forName: "iapRestore")
        }

        webView.configuration.userContentController.add(self, name: "iapPurchase")
        webView.configuration.userContentController.add(self, name: "iapRestore")
        attachedWebView = webView

        print("✅ IAPBridge: erfolgreich an WebView angehängt")

        if !isListening {
            isListening = true
            Task {
                await self.listenForTransactionUpdates()
            }
        }
    }

    // MARK: - Nachrichten aus JavaScript empfangen

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "iapPurchase":
            Task { await self.purchase() }
        case "iapRestore":
            Task { await self.restore() }
        default:
            break
        }
    }

    // MARK: - Kauf durchführen

    private func purchase() async {
        do {
            let products = try await Product.products(for: [productId])
            guard let product = products.first else {
                callJS(function: "onIAPError", arg: "Produkt nicht im App Store gefunden.")
                return
            }

            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    callJS(function: "onIAPSuccess")
                case .unverified(_, let error):
                    callJS(function: "onIAPError", arg: "Kauf konnte nicht verifiziert werden: \(error.localizedDescription)")
                }
            case .userCancelled:
                break
            case .pending:
                callJS(function: "onIAPError", arg: "Kauf ist ausstehend (z.B. Kindersicherung). Bitte \"Kauf wiederherstellen\" später erneut versuchen.")
            @unknown default:
                callJS(function: "onIAPError", arg: "Unbekannter Fehler beim Kauf.")
            }
        } catch {
            callJS(function: "onIAPError", arg: "Kauf fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: - Kauf wiederherstellen

    private func restore() async {
        var foundValidPurchase = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == productId {
                foundValidPurchase = true
                await transaction.finish()
            }
        }

        if foundValidPurchase {
            callJS(function: "onIAPRestoreSuccess")
        } else {
            callJS(function: "onIAPRestoreEmpty")
        }
    }

    // MARK: - Offene/verpasste Transaktionen automatisch nachreichen

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            await transaction.finish()
            if transaction.productID == productId {
                callJS(function: "onIAPSuccess")
            }
        }
    }

    // MARK: - Hilfsfunktion: JavaScript im WebView aufrufen

    private func callJS(function: String, arg: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.attachedWebView else { return }
            let js: String
            if let arg = arg {
                let escaped = arg
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                js = "\(function)('\(escaped)')"
            } else {
                js = "\(function)()"
            }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
