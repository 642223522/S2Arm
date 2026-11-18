// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation

/// 0.6.0 通用壳（开关后面）iPhone 总控台用的「这台手机的全貌」（作业 phoneOverview，pack/jobs）：每台见过的手机、App 状态、每款在这台上的状态。
///   probe = false 只读设备记录（秒回）；true 才问 USB 上连着谁（online）。开关关着作业回 enabled = false → nil
public struct PhoneOverview: Equatable {
    public enum SignMode: String { case appleId, devCert, external }
    public enum GameState: String { case latest, suggested, notPushed, needsData }
    public struct Game: Equatable {
        public let gameId: String
        public let state: GameState
        public let reasons: [String]
        /// 电脑上这款的资源（game.img）还在不在：needsData / notPushed 的款，不在就要原件
        public let dataOnComputer: Bool?
        public init(gameId: String, state: GameState, reasons: [String], dataOnComputer: Bool?) {
            self.gameId = gameId; self.state = state; self.reasons = reasons; self.dataOnComputer = dataOnComputer
        }
    }
    public struct Phone: Equatable {
        public let device: String
        public let name: String
        public let installed: Bool
        public let shellCurrent: Bool
        public let bundleId: String
        public let signedAt: Date?
        public let free: Bool
        /// 按苹果规则估的到期（免费 7 天、付费一年）；界面写「约」，准数以手机上 App 为准
        public let expiresAtEstimate: Date?
        /// 只有 probe 时才有：nil = 没问（没 probe），.some(nil) = 问了、没连
        public let online: String??
        public let lastSeen: Date?
        public let signMode: SignMode?
        public let games: [Game]
        public init(device: String, name: String, installed: Bool, shellCurrent: Bool, bundleId: String, signedAt: Date?, free: Bool,
                    expiresAtEstimate: Date?, online: String??, lastSeen: Date?, signMode: SignMode?, games: [Game]) {
            self.device = device; self.name = name; self.installed = installed; self.shellCurrent = shellCurrent; self.bundleId = bundleId
            self.signedAt = signedAt; self.free = free; self.expiresAtEstimate = expiresAtEstimate; self.online = online; self.lastSeen = lastSeen
            self.signMode = signMode; self.games = games
        }
    }
    public let phones: [Phone]

    public init(phones: [Phone]) { self.phones = phones }

    /// 作业结果 → 总览；开关关着（enabled 不是 true）→ nil
    public init?(result r: [String: Any]) {
        guard r["enabled"] as? Bool == true else { return nil }
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        phones = (r["phones"] as? [[String: Any]] ?? []).compactMap { p in
            guard let device = p["device"] as? String, !device.isEmpty else { return nil }
            let online: String?? = p.keys.contains("online") ? .some(p["online"] as? String) : nil
            let games: [Game] = (p["games"] as? [[String: Any]] ?? []).compactMap { g in
                guard let id = g["gameId"] as? String, let s = (g["state"] as? String).flatMap(GameState.init) else { return nil }
                return Game(gameId: id.uppercased(), state: s, reasons: g["reasons"] as? [String] ?? [], dataOnComputer: g["dataOnComputer"] as? Bool)
            }
            return Phone(device: device, name: p["name"] as? String ?? "", installed: p["installed"] as? Bool == true, shellCurrent: p["shellCurrent"] as? Bool == true,
                         bundleId: p["bundleId"] as? String ?? "", signedAt: date(p["signedAt"]), free: p["free"] as? Bool == true,
                         expiresAtEstimate: date(p["expiresAtEstimate"]), online: online, lastSeen: date(p["lastSeen"]),
                         signMode: (p["signMode"] as? String).flatMap(SignMode.init), games: games)
        }
    }
}
