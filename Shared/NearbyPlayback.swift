#if os(iOS) || os(macOS)
import CryptoKit
import Foundation
import MultipeerConnectivity
import Observation

/// The Mac advertises on the local network. The iPhone links to it with the code shown on the Mac.
@Observable @MainActor
final class NearbyPlayback: NSObject {
    static let shared = NearbyPlayback()
    private static let service = "soundbase-play"
    private static let codeKey = "nearbyPlaybackCode"

    private(set) var connected = false
    private(set) var pairingCode: String
    private(set) var status: String?
    #if os(macOS)
    private(set) var sharingEnabled = UserDefaults.standard.bool(forKey: "nearbyPlaybackEnabled")
    #endif
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onState: (([String: Any]) -> Void)?
    @ObservationIgnored var handle: (([String: Any]) async -> [String: Any])?

    @ObservationIgnored private let peer = MCPeerID(displayName: UUID().uuidString)
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var peerInProgress: MCPeerID?
    @ObservationIgnored private var verifiedPeer: MCPeerID?
    @ObservationIgnored private var pending: [String: CheckedContinuation<[String: Any]?, Never>] = [:]
    @ObservationIgnored private var challenge = UUID().uuidString
    @ObservationIgnored private var receivedRequests: Set<String> = []

    private override init() {
        #if os(macOS)
        let code = UserDefaults.standard.string(forKey: Self.codeKey) ??
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        pairingCode = code
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        #else
        pairingCode = UserDefaults.standard.string(forKey: Self.codeKey) ?? ""
        #endif
        super.init()
    }

    var displayCode: String {
        pairingCode.enumerated().reduce(into: "") { result, entry in
            if entry.offset > 0, entry.offset.isMultiple(of: 6) { result += "-" }
            result.append(entry.element)
        }
    }

    func start() {
        guard session == nil, !pairingCode.isEmpty else { return }
        #if os(macOS)
        guard sharingEnabled else { return }
        #endif
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        self.session = session
        session.delegate = self
        #if os(macOS)
        challenge = UUID().uuidString
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: [
            "challenge": challenge, "proof": discoveryProof(challenge).base64EncodedString()
        ],
                                                    serviceType: Self.service)
        self.advertiser = advertiser
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        #else
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
        self.browser = browser
        browser.delegate = self
        browser.startBrowsingForPeers()
        #endif
    }

    #if os(iOS)
    func pair(code: String) {
        let normalized = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard normalized.count == 24, normalized.allSatisfy({ $0.isHexDigit }) else {
            status = "Enter the code shown in SoundBase on your Mac."
            return
        }
        reset()
        pairingCode = normalized
        UserDefaults.standard.set(normalized, forKey: Self.codeKey)
        status = "Looking for your Mac…"
        start()
    }

    func forgetMac() {
        reset()
        pairingCode = ""
        status = nil
        UserDefaults.standard.removeObject(forKey: Self.codeKey)
    }
    #endif

    #if os(macOS)
    func setSharing(_ enabled: Bool) {
        sharingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "nearbyPlaybackEnabled")
        if enabled { start() } else { reset() }
    }

    func regenerateCode() {
        reset()
        pairingCode = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        UserDefaults.standard.set(pairingCode, forKey: Self.codeKey)
        start()
    }
    #endif

    func reset() {
        let old = session
        session = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        old?.disconnect()
        peerInProgress = nil
        disconnected()
    }

    func request(_ message: [String: Any]) async -> [String: Any]? {
        guard let verifiedPeer else { return nil }
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            guard send(["request": id, "body": message], to: verifiedPeer) else {
                pending.removeValue(forKey: id)?.resume(returning: nil)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.pending.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    func publish(_ state: [String: Any]) {
        guard let verifiedPeer else { return }
        _ = send(["state": state], to: verifiedPeer)
    }

    private var key: SymmetricKey { SymmetricKey(data: SHA256.hash(data: Data(pairingCode.utf8))) }

    private func inviteProof(_ challenge: String, _ phone: MCPeerID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("invite:\(challenge):\(phone.displayName)".utf8), using: key))
    }

    private func discoveryProof(_ challenge: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("discover:\(challenge)".utf8), using: key))
    }

    private func send(_ payload: [String: Any], to target: MCPeerID) -> Bool {
        guard let session,
              let plist = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0),
              let data = try? ChaChaPoly.seal(plist, using: key).combined else { return false }
        do {
            try session.send(data, toPeers: [target], with: .reliable)
            return true
        } catch { return false }
    }

    private func receive(_ data: Data, from sender: MCPeerID) async {
        guard sender == peerInProgress, data.count < 150_000,
              let box = try? ChaChaPoly.SealedBox(combined: data),
              let raw = try? ChaChaPoly.open(box, using: key),
              let message = (try? PropertyListSerialization.propertyList(from: raw, format: nil)) as? [String: Any] else { return }
        if let hello = message["hello"] as? String, hello == challenge {
            verifiedPeer = sender
            connected = true
            status = nil
            #if os(macOS)
            _ = send(["hello": challenge], to: sender)
            #endif
            onChange?()
        } else if sender == verifiedPeer {
            if let state = message["state"] as? [String: Any] { onState?(state) }
            if let reply = message["reply"] as? String {
                pending.removeValue(forKey: reply)?.resume(returning: message["body"] as? [String: Any])
            }
            if let id = message["request"] as? String, let body = message["body"] as? [String: Any],
               receivedRequests.count < 50_000, receivedRequests.insert(id).inserted {
                let response = await handle?(body) ?? [WatchKey.success: false]
                _ = send(["reply": id, "body": response], to: sender)
            }
        }
    }

    private func disconnected() {
        verifiedPeer = nil
        connected = false
        receivedRequests.removeAll()
        let requests = pending
        pending.removeAll()
        for request in requests.values { request.resume(returning: nil) }
        onChange?()
    }
}

extension NearbyPlayback: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard self.session === session, self.peerInProgress == peerID else { return }
            if state == .connected {
                #if os(iOS)
                _ = self.send(["hello": self.challenge], to: peerID)
                #endif
            } else if state == .notConnected {
                self.peerInProgress = nil
                self.disconnected()
                #if os(iOS)
                self.status = "Mac unavailable. Check the pairing code and local network."
                self.browser?.stopBrowsingForPeers()
                try? await Task.sleep(for: .seconds(3))
                self.browser?.startBrowsingForPeers()
                #endif
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard self.session === session else { return }
            await self.receive(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension NearbyPlayback: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard self.browser === browser, self.peerInProgress == nil,
                  let challenge = info?["challenge"], let proof = info?["proof"],
                  proof == self.discoveryProof(challenge).base64EncodedString(),
                  let session = self.session else { return }
            self.challenge = challenge
            self.peerInProgress = peerID
            browser.invitePeer(peerID, to: session, withContext: self.inviteProof(challenge, self.peer), timeout: 8)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.status = "Allow local network access to connect to your Mac." }
    }
}

extension NearbyPlayback: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.status = "Allow local network access to share playback." }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard self.advertiser === advertiser, self.peerInProgress == nil, let session = self.session,
                  let context, HMAC<SHA256>.isValidAuthenticationCode(context,
                      authenticating: Data("invite:\(self.challenge):\(peerID.displayName)".utf8), using: self.key) else {
                invitationHandler(false, nil)
                return
            }
            self.peerInProgress = peerID
            invitationHandler(true, session)
        }
    }
}
#endif
