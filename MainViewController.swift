//
//  MainViewController.swift
//  LogTa Logistiker
//
//  Ersetzt/ergänzt die Standard-Capacitor-ViewController-Klasse.
//  Implementiert den Apple In-App-Kauf mit StoreKit 2 und meldet
//  Erfolg/Fehler zuverlässig an das JavaScript im WebView zurück.
//
//  WICHTIG: Diese Datei MUSS ins Git-Repo eingecheckt werden
//  (zusammen mit dem kompletten ios/-Ordner), sonst geht sie bei
//  jedem automatischen Build (npx cap add ios) wieder verloren!
//

import UIKit
import Capacitor
import WebKit
import StoreKit

class MainViewController: CAPBridgeViewController, WKScriptMessageHandler {

    // Muss exakt mit IAP_PRODUCT_ID in der HTML/JS-Datei übereinstimmen
    private let productId = "com.logta.logistiker.fullversion"

    // MARK: - Setup

    override func capacitorDidLoad() {
        super.capacitorDidLoad()

        guard let webView = self.bridge?.webView else {
            print("⚠️ IAP: WebView nicht verfügbar, Message Handler konnten nicht registriert werden.")
            return
        }

        // Empfängt die postMessage-Aufrufe aus der HTML-Datei:
        // window.webkit.messageHandlers.iapPurchase.postMessage(...)
        // window.webkit.messageHandlers.iapRestore.postMessage(...)
        webView.configuration.userContentController.add(self, name: "iapPurchase")
        webView.configuration.userContentController.add(self, name: "iapRestore")

        // KRITISCH: Hört dauerhaft auf Transaktions-Updates von StoreKit.
        // Das fängt genau den Fall ab, der wahrscheinlich den Bug verursacht hat:
        // Ein Kauf wird bei Apple bestätigt, aber die App bekommt es (z.B. wegen
        // App-Wechsel, Netzwerkaussetzer, Absturz) im Moment nicht mit.
        // StoreKit liefert die Transaktion dann später HIER erneut aus.
        Task {
            await self.listenForTransactionUpdates()
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
                    // Transaktion IMMER abschließen – egal was als nächstes passiert.
                    // Wird das vergessen/übersprungen, bleibt die Transaktion in der
                    // StoreKit-Queue "offen" und Apple liefert sie beim nächsten
                    // App-Start erneut als unbezahlt/unbestätigt aus -> genau der Bug!
                    await transaction.finish()
                    callJS(function: "onIAPSuccess")

                case .unverified(_, let error):
                    callJS(function: "onIAPError", arg: "Kauf konnte nicht verifiziert werden: \(error.localizedDescription)")
                }

            case .userCancelled:
                // Kein Fehler-Alert nötig, User hat bewusst abgebrochen
                break

            case .pending:
                callJS(function: "onIAPError", arg: "Kauf ist ausstehend (z.B. Kindersicherung oder Zahlungsprüfung). Bitte später erneut prüfen oder \"Kauf wiederherstellen\" nutzen.")

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

        // Prüft alle aktuell gültigen Berechtigungen direkt bei Apple,
        // unabhängig vom lokalen Zustand der App.
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
        // Diese Schleife läuft dauerhaft im Hintergrund, solange die App lebt.
        // StoreKit ruft sie automatisch auf, sobald irgendeine Transaktion
        // (auch von einem früheren App-Start, der abgebrochen wurde) bereit ist.
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
        DispatchQueue.main.async {
            let js: String
            if let arg = arg {
                let escaped = arg
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                js = "\(function)('\(escaped)')"
            } else {
                js = "\(function)()"
            }
            self.bridge?.webView?.evaluateJavaScript(js, completionHandler: { _, error in
                if let error = error {
                    print("⚠️ IAP: Fehler beim JS-Callback \(function): \(error)")
                }
            })
        }
    }
}
