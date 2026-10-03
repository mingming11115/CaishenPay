import Foundation
import CryptoKit
import WatchConnectivity
import WorkPayCore

/// Phone state is authoritative for rules and the ledger. Watch packets only carry work edits.
struct PaySyncPacket: Codable {
    enum Source: String, Codable { case phone, watch }
    var version = 1
    var source: Source
    var deviceID: String
    var revision: Int64
    var data: PayData?
    var entries: [WorkEntry]
    var acknowledged: [WorkEntry]
}

@MainActor
final class ConnectivityService: NSObject, WCSessionDelegate {
    var onReceive: ((PaySyncPacket) -> Void)?
    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    private var session: WCSession?
    nonisolated private static let payloadKey = "caishen.payload.v1"

    func activate() {
        guard WCSession.isSupported() else {
            onStatus?("此设备不支持手表同步")
            return
        }
        let connection = WCSession.default
        session = connection
        connection.delegate = self
        connection.activate()
        onStatus?("正在连接")
    }

    func send(_ packet: PaySyncPacket) {
        guard let session, session.activationState == .activated else {
            onStatus?("已保存在本机 · 等待连接")
            return
        }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else {
            onStatus?(session.isPaired ? "请在手表安装财神记薪" : "未配对 Apple Watch")
            return
        }
        #endif
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(packet)
            let context: [String: Any] = [Self.payloadKey: payload]
            if payload.count > 50_000 {
                // WatchConnectivity messages are small. Larger histories use its queued file transport.
                try queueFile(payload, source: packet.source, session: session)
                onStatus?("历史记录已排队 · 等待同步")
                return
            } else if packet.source == .phone {
                // Application context delivers the newest complete phone state after reconnect.
                try session.updateApplicationContext(context)
            } else if !packet.entries.isEmpty {
                // The durable store remains the outbox until the phone acknowledges exact versions.
                // WCSession also queues delivery while either app is suspended.
                let alreadyQueued = session.outstandingUserInfoTransfers.contains {
                    ($0.userInfo[Self.payloadKey] as? Data) == payload
                }
                if !alreadyQueued { session.transferUserInfo(context) }
            }
            if session.isReachable {
                session.sendMessageData(payload, replyHandler: nil) { [weak self] _ in
                    Task { @MainActor in self?.onStatus?("暂时离线 · 数据已保留") }
                }
                onStatus?(packet.entries.isEmpty ? "已连接" : "正在同步")
            } else {
                onStatus?(packet.entries.isEmpty ? "暂时离线 · 显示本机数据" : "已保存在本机 · 等待同步")
            }
        } catch {
            onStatus?("同步暂未完成 · 本机数据已保留")
        }
    }

    private func queueFile(_ payload: Data, source: PaySyncPacket.Source, session: WCSession) throws {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard !session.outstandingFileTransfers.contains(where: { ($0.file.metadata?["digest"] as? String) == digest }) else { return }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CaishenSync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(digest + "-" + UUID().uuidString + ".json")
        try payload.write(to: file, options: .atomic)
        session.transferFile(file, metadata: ["format": Self.payloadKey, "digest": digest, "source": source.rawValue])
    }

    private func receive(_ payload: Data) {
        guard payload.count < 20_000_000 else {
            onStatus?("同步数据过大，请在手机检查")
            return
        }
        do {
            let packet = try JSONDecoder().decode(PaySyncPacket.self, from: payload)
            guard packet.version == 1 else {
                onStatus?("请将手机和手表更新至同一版本")
                return
            }
            onReceive?(packet)
        } catch {
            onStatus?("同步数据无法读取 · 本机数据已保留")
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.onStatus?("连接未完成：\(error.localizedDescription)")
            } else if activationState == .activated {
                if let payload = session.receivedApplicationContext[Self.payloadKey] as? Data {
                    self.receive(payload)
                }
                self.onReady?()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.onStatus?(session.isReachable ? "已连接" : "暂时离线 · 显示本机数据")
            if session.isReachable { self?.onReady?() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let payload = applicationContext[Self.payloadKey] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(payload) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let payload = userInfo[Self.payloadKey] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(payload) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in self?.receive(messageData) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard (file.metadata?["format"] as? String) == Self.payloadKey else { return }
        // Received files exist only for this delegate callback; copy their bytes before returning.
        do {
            let payload = try Data(contentsOf: file.fileURL)
            Task { @MainActor [weak self] in self?.receive(payload) }
        } catch {
            Task { @MainActor [weak self] in self?.onStatus?("历史记录尚未读取 · 请重新同步") }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard (fileTransfer.file.metadata?["format"] as? String) == Self.payloadKey else { return }
        let file = fileTransfer.file.fileURL
        if file.deletingLastPathComponent().lastPathComponent == "CaishenSync" {
            try? FileManager.default.removeItem(at: file)
        }
        if error != nil {
            Task { @MainActor [weak self] in self?.onStatus?("历史记录尚未送达 · 下次连接会重试") }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if error != nil {
            Task { @MainActor [weak self] in self?.onStatus?("尚未送达 · 下次连接会重试") }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.onReady?() }
    }
    #endif
}
