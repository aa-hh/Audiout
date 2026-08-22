// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation

/// One application running on a receiver, as it appears in RECEIVER_STATUS.
public struct CastApplication: Equatable {
    public let appID: String
    public let displayName: String
    /// Identifies the session to the RECEIVER namespace (STOP, LOAD).
    public let sessionID: String
    /// The endpoint id media messages are addressed to.
    public let transportID: String

    public init(appID: String, displayName: String, sessionID: String, transportID: String) {
        self.appID = appID
        self.displayName = displayName
        self.sessionID = sessionID
        self.transportID = transportID
    }
}

public struct CastReceiverStatus: Equatable {
    public let volumeLevel: Double
    public let muted: Bool
    public let applications: [CastApplication]

    /// An application without a `transportId` or `sessionId` cannot be
    /// addressed at all, so it is dropped rather than surfaced half-usable.
    public static func parse(_ json: [String: Any]) -> CastReceiverStatus {
        let status = json["status"] as? [String: Any] ?? [:]
        let volume = status["volume"] as? [String: Any] ?? [:]
        let applications = (status["applications"] as? [[String: Any]] ?? []).compactMap { entry -> CastApplication? in
            guard let transportID = entry["transportId"] as? String,
                  let sessionID = entry["sessionId"] as? String else { return nil }
            return CastApplication(
                appID: entry["appId"] as? String ?? "",
                displayName: entry["displayName"] as? String ?? "",
                sessionID: sessionID,
                transportID: transportID
            )
        }
        return CastReceiverStatus(
            volumeLevel: volume["level"] as? Double ?? 0,
            muted: volume["muted"] as? Bool ?? false,
            applications: applications
        )
    }
}

public struct CastMediaStatus: Equatable {
    public let mediaSessionID: Int?
    public let playerState: String
    public let idleReason: String?
    public let currentTime: Double?

    /// An empty `status` array is how a receiver says "nothing loaded".
    public static func parse(_ json: [String: Any]) -> CastMediaStatus {
        guard let first = (json["status"] as? [[String: Any]])?.first else {
            return CastMediaStatus(mediaSessionID: nil, playerState: "IDLE", idleReason: nil, currentTime: nil)
        }
        return CastMediaStatus(
            mediaSessionID: first["mediaSessionId"] as? Int,
            playerState: first["playerState"] as? String ?? "IDLE",
            idleReason: first["idleReason"] as? String,
            currentTime: first["currentTime"] as? Double
        )
    }
}

/// The verbs of the RECEIVER and MEDIA namespaces, over one ``CastChannel``.
/// Every completion runs on the channel's queue.
public final class CastClient: @unchecked Sendable {

    /// Google's Default Media Receiver — the stock app that plays a URL, with
    /// no developer registration behind it (roadmap 006 brief, decision 3).
    public static let defaultMediaReceiverAppID = "CC1AD845"

    public let channel: CastChannel

    /// Fires for EVERY media status, whether it answered a request of ours or
    /// the receiver volunteered it. Playback-state changes on a live receiver
    /// mostly arrive unsolicited.
    public var onMediaStatus: ((CastMediaStatus) -> Void)?

    public init(channel: CastChannel) {
        self.channel = channel
        channel.onUnsolicited = { [weak self] message, json in
            guard let self,
                  message.namespace == CastNamespace.media,
                  (json["type"] as? String) == "MEDIA_STATUS" else { return }
            self.onMediaStatus?(CastMediaStatus.parse(json))
        }
    }

    // MARK: - Receiver namespace

    public func getReceiverStatus(completion: @escaping (Result<CastReceiverStatus, Error>) -> Void) {
        receiverRequest(["type": "GET_STATUS"], completion: completion)
    }

    public func setVolume(level: Double, completion: @escaping (Result<CastReceiverStatus, Error>) -> Void) {
        receiverRequest(["type": "SET_VOLUME", "volume": ["level": level]], completion: completion)
    }

    public func setMuted(_ muted: Bool, completion: @escaping (Result<CastReceiverStatus, Error>) -> Void) {
        receiverRequest(["type": "SET_VOLUME", "volume": ["muted": muted]], completion: completion)
    }

    public func stopApplication(sessionID: String, completion: @escaping (Result<CastReceiverStatus, Error>) -> Void) {
        receiverRequest(["type": "STOP", "sessionId": sessionID], completion: completion)
    }

    /// Starts `appID` and opens the virtual connection to its transport id, so
    /// the caller can address media messages to the returned application
    /// immediately.
    public func launch(appID: String, completion: @escaping (Result<CastApplication, Error>) -> Void) {
        receiverRequest(["type": "LAUNCH", "appId": appID]) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let status):
                guard let app = status.applications.first(where: { $0.appID == appID }) else {
                    completion(.failure(CastError.applicationNotInStatus(appID: appID)))
                    return
                }
                self?.channel.connectVirtual(to: app.transportID)
                completion(.success(app))
            }
        }
    }

    private func receiverRequest(_ payload: [String: Any], completion: @escaping (Result<CastReceiverStatus, Error>) -> Void) {
        channel.request(namespace: CastNamespace.receiver, destination: CastIDs.platform, payload: payload) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let type = json["type"] as? String ?? ""
                guard type == "RECEIVER_STATUS" else {
                    completion(.failure(CastError.receiverError(type: type, reason: json["reason"] as? String)))
                    return
                }
                completion(.success(CastReceiverStatus.parse(json)))
            }
        }
    }

    // MARK: - Media namespace

    /// `streamType: "LIVE"` — the stream has no known duration and no seek
    /// point, which is what an endless system-audio feed is.
    public func load(
        url: URL,
        contentType: String,
        streamType: String = "LIVE",
        autoplay: Bool = true,
        app: CastApplication,
        completion: @escaping (Result<CastMediaStatus, Error>) -> Void
    ) {
        mediaRequest([
            "type": "LOAD",
            "sessionId": app.sessionID,
            "media": [
                "contentId": url.absoluteString,
                "contentType": contentType,
                "streamType": streamType,
            ],
            "autoplay": autoplay,
            "currentTime": 0,
        ], app: app, completion: completion)
    }

    public func play(mediaSessionID: Int, app: CastApplication, completion: @escaping (Result<CastMediaStatus, Error>) -> Void) {
        mediaRequest(["type": "PLAY", "mediaSessionId": mediaSessionID], app: app, completion: completion)
    }

    public func pause(mediaSessionID: Int, app: CastApplication, completion: @escaping (Result<CastMediaStatus, Error>) -> Void) {
        mediaRequest(["type": "PAUSE", "mediaSessionId": mediaSessionID], app: app, completion: completion)
    }

    public func stopMedia(mediaSessionID: Int, app: CastApplication, completion: @escaping (Result<CastMediaStatus, Error>) -> Void) {
        mediaRequest(["type": "STOP", "mediaSessionId": mediaSessionID], app: app, completion: completion)
    }

    public func getMediaStatus(app: CastApplication, completion: @escaping (Result<CastMediaStatus, Error>) -> Void) {
        mediaRequest(["type": "GET_STATUS"], app: app, completion: completion)
    }

    private func mediaRequest(
        _ payload: [String: Any],
        app: CastApplication,
        completion: @escaping (Result<CastMediaStatus, Error>) -> Void
    ) {
        channel.request(namespace: CastNamespace.media, destination: app.transportID, payload: payload) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let type = json["type"] as? String ?? ""
                guard type == "MEDIA_STATUS" else {
                    completion(.failure(CastError.receiverError(type: type, reason: json["reason"] as? String)))
                    return
                }
                let status = CastMediaStatus.parse(json)
                self?.onMediaStatus?(status)
                completion(.success(status))
            }
        }
    }
}
