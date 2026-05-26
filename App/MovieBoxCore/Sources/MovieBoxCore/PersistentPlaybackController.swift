import CoreMetadata
import CorePlayer
import CoreStreaming
import CoreTorrent
import Foundation
import Observation

// MARK: - Models

public enum PersistentPlaybackPhase: Equatable {
    case idle
    case preparing
    case buffering(progress: Double, statusLine: String)
    case openingPlayer
    case failed(String)
}

public struct PersistentPlaybackItem: Equatable {
    public let movieId: Int
    public let mediaKind: MediaKind
    public let title: String
    public let posterURL: URL?
    public let qualityLabel: String
    public let episodeTitle: String?
    public let activeTorrentID: UUID
    public let releaseTitle: String
    public let detailLine: String
    public let seeders: Int
    public let leechers: Int

    public init(
        movieId: Int,
        mediaKind: MediaKind,
        title: String,
        posterURL: URL?,
        qualityLabel: String,
        episodeTitle: String?,
        activeTorrentID: UUID,
        releaseTitle: String,
        detailLine: String,
        seeders: Int,
        leechers: Int
    ) {
        self.movieId = movieId
        self.mediaKind = mediaKind
        self.title = title
        self.posterURL = posterURL
        self.qualityLabel = qualityLabel
        self.episodeTitle = episodeTitle
        self.activeTorrentID = activeTorrentID
        self.releaseTitle = releaseTitle
        self.detailLine = detailLine
        self.seeders = seeders
        self.leechers = leechers
    }

    public static func make(
        request: PersistentPlaybackStartRequest,
        torrent: TorrentResult
    ) -> PersistentPlaybackItem {
        var parts: [String] = []
        if torrent.sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: torrent.sizeBytes, countStyle: .file))
        }
        parts.append(torrent.codec.rawValue)
        if torrent.source != .unknown {
            parts.append(torrent.source.rawValue)
        }
        return PersistentPlaybackItem(
            movieId: request.movieId,
            mediaKind: request.mediaKind,
            title: request.title,
            posterURL: request.posterURL,
            qualityLabel: torrent.quality.rawValue,
            episodeTitle: request.episodeTitle,
            activeTorrentID: torrent.id,
            releaseTitle: torrent.title,
            detailLine: parts.joined(separator: " · "),
            seeders: torrent.seeders,
            leechers: torrent.leechers
        )
    }
}

public struct PersistentPlaybackStartRequest: Sendable {
    public enum Mode: Sendable {
        case single(TorrentResult)
        case bestAvailable(torrents: [TorrentResult], maxAttempts: Int)
    }

    public let mode: Mode
    public let movieId: Int
    public let mediaKind: MediaKind
    public let allTorrents: [TorrentResult]
    public let posterURL: URL?
    public let title: String
    public let episodeTitle: String?
    public let displayTitle: String?
    public let subtitleURL: URL?
    public let subtitleCatalog: [SubtitleInfo]
    public let selectedSubtitleID: String?
    public let subtitleSearchContext: SubtitleSearchContext?
    public let playback: PlaybackSettings
    public let resumePosition: Double?
    public let knownDurationSeconds: Double?
    public let waitTimeout: TimeInterval
    public let onSessionStarted: (@MainActor (TorrentStreamSession) -> Void)?
    public let onPlaybackOpened: (@MainActor (TorrentResult) -> Void)?

    public init(
        mode: Mode,
        movieId: Int,
        mediaKind: MediaKind,
        allTorrents: [TorrentResult],
        posterURL: URL?,
        title: String,
        episodeTitle: String? = nil,
        displayTitle: String? = nil,
        subtitleURL: URL? = nil,
        subtitleCatalog: [SubtitleInfo] = [],
        selectedSubtitleID: String? = nil,
        subtitleSearchContext: SubtitleSearchContext? = nil,
        playback: PlaybackSettings,
        resumePosition: Double? = nil,
        knownDurationSeconds: Double? = nil,
        waitTimeout: TimeInterval = 180,
        onSessionStarted: (@MainActor (TorrentStreamSession) -> Void)? = nil,
        onPlaybackOpened: (@MainActor (TorrentResult) -> Void)? = nil
    ) {
        self.mode = mode
        self.movieId = movieId
        self.mediaKind = mediaKind
        self.allTorrents = allTorrents
        self.posterURL = posterURL
        self.title = title
        self.episodeTitle = episodeTitle
        self.displayTitle = displayTitle
        self.subtitleURL = subtitleURL
        self.subtitleCatalog = subtitleCatalog
        self.selectedSubtitleID = selectedSubtitleID
        self.subtitleSearchContext = subtitleSearchContext
        self.playback = playback
        self.resumePosition = resumePosition
        self.knownDurationSeconds = knownDurationSeconds
        self.waitTimeout = waitTimeout
        self.onSessionStarted = onSessionStarted
        self.onPlaybackOpened = onPlaybackOpened
    }

    var primaryTorrent: TorrentResult {
        switch mode {
        case .single(let torrent):
            torrent
        case .bestAvailable(let torrents, _):
            Self.orderedCandidates(from: torrents).first ?? torrents[0]
        }
    }

    static func orderedCandidates(from torrents: [TorrentResult]) -> [TorrentResult] {
        let seeded = torrents.filter { $0.seeders > 0 }
        let candidates = seeded.isEmpty ? torrents : seeded
        return candidates.sorted { lhs, rhs in
            if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }
}

public enum PersistentPlaybackStartResult: Equatable {
    case started
    case needsConfirmation
}

/// Throttled, equatable snapshot for SwiftUI — updates only when display values change.
public struct PersistentPlaybackUITick: Equatable, Sendable {
    public var movieId: Int?
    public var torrentId: UUID?
    public var progressPercent: Int
    public var phaseLabel: String
    public var phaseDetail: String
    public var statusLine: String
    public var rowPhase: String
    public var rowDetail: String
    public var isActive: Bool

    public static let inactive = PersistentPlaybackUITick(
        movieId: nil,
        torrentId: nil,
        progressPercent: 0,
        phaseLabel: "",
        phaseDetail: "",
        statusLine: "",
        rowPhase: "",
        rowDetail: "",
        isActive: false
    )

    public var rowSnapshot: TorrentRowBufferingSnapshot {
        TorrentRowBufferingSnapshot(
            progress: Double(progressPercent) / 100,
            phase: rowPhase,
            detail: rowDetail
        )
    }
}

// MARK: - Controller

@MainActor
@Observable
public final class PersistentPlaybackController {
    public private(set) var phase: PersistentPlaybackPhase = .idle
    public private(set) var item: PersistentPlaybackItem?
    public private(set) var pendingRequest: PersistentPlaybackStartRequest?
    /// Coalesced UI state — observers should prefer this over raw `phase` to reduce lag.
    public private(set) var uiTick: PersistentPlaybackUITick = .inactive
    /// Short status for UI chrome (e.g. "Loading MKV index (cues)…").
    public private(set) var phaseLabel: String = ""
    /// Detail line (peers, speed, head/tail bytes).
    public private(set) var phaseDetail: String = ""

    private var pipelineTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var lastPublishedTick: PersistentPlaybackUITick = .inactive
    private var lastPublishedDetailLine: String = ""
    private var lastDetailPublishTime: ContinuousClock.Instant?
    private static let detailPublishMinInterval: Duration = .milliseconds(1500)
    public private(set) var activeTorrentID: UUID?
    /// True briefly after start so the list row can morph into the shell pill.
    public var isActive: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    public var progress: Double {
        switch phase {
        case .buffering(let progress, _): progress
        case .openingPlayer: 1
        default: 0
        }
    }

    public var statusLine: String {
        switch phase {
        case .preparing: "Starting stream…"
        case .buffering(_, let line): line
        case .openingPlayer: "Opening player…"
        case .failed(let message): message
        case .idle: ""
        }
    }

    public init() {}

    @discardableResult
    public func start(
        request: PersistentPlaybackStartRequest,
        appServices: AppServices,
        playerState: PlayerState
    ) -> PersistentPlaybackStartResult {
        let torrent = request.primaryTorrent

        if isActive, let activeID = activeTorrentID, activeID != torrent.id {
            pendingRequest = request
            return .needsConfirmation
        }

        beginPipeline(request: request, appServices: appServices, playerState: playerState)
        return .started
    }

    public func confirmReplaceAndStart(appServices: AppServices, playerState: PlayerState) {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        Task {
            await cancel(appServices: appServices)
            beginPipeline(request: request, appServices: appServices, playerState: playerState)
        }
    }

    public func dismissPendingRequest() {
        pendingRequest = nil
    }

    public func cancel(appServices: AppServices) async {
        pipelineTask?.cancel()
        pipelineTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        await appServices.cancelActiveStreamWithoutPersistentReset()
        activeTorrentID = nil
        item = nil
        phase = .idle
        phaseLabel = ""
        phaseDetail = ""
        publishUITick(.inactive)
    }

    public func isBuffering(movieId: Int) -> Bool {
        isActive && item?.movieId == movieId
    }

    public func rowSnapshot(for torrentId: UUID, movieId: Int) -> TorrentRowBufferingSnapshot? {
        guard isActive, item?.movieId == movieId, activeTorrentID == torrentId else { return nil }
        if uiTick.torrentId == torrentId, uiTick.movieId == movieId {
            return uiTick.rowSnapshot
        }
        return .starting
    }

    private func beginPipeline(
        request: PersistentPlaybackStartRequest,
        appServices: AppServices,
        playerState: PlayerState
    ) {
        pipelineTask?.cancel()
        monitorTask?.cancel()

        let torrent = request.primaryTorrent
        activeTorrentID = torrent.id
        item = PersistentPlaybackItem.make(request: request, torrent: torrent)
        phase = .preparing
        if let posterURL = request.posterURL {
            playerState.posterURL = posterURL
        }
        publishUITick(
            PersistentPlaybackUITick(
                movieId: request.movieId,
                torrentId: torrent.id,
                progressPercent: 4,
                phaseLabel: TorrentRowBufferingSnapshot.starting.phase,
                phaseDetail: TorrentRowBufferingSnapshot.starting.detail,
                statusLine: "Starting stream…",
                rowPhase: TorrentRowBufferingSnapshot.starting.phase,
                rowDetail: TorrentRowBufferingSnapshot.starting.detail,
                isActive: true
            )
        )

        pipelineTask = Task { @MainActor in
            await runPipeline(request: request, appServices: appServices, playerState: playerState)
        }
    }

    private func runPipeline(
        request: PersistentPlaybackStartRequest,
        appServices: AppServices,
        playerState: PlayerState
    ) async {
        let coordinator = appServices.beginPlaybackCoordinator()

        switch request.mode {
        case .single(let torrent):
            await runSingleAttempt(
                torrent: torrent,
                request: request,
                coordinator: coordinator,
                appServices: appServices,
                playerState: playerState
            )

        case .bestAvailable(let torrents, let maxAttempts):
            await runBestAvailableAttempts(
                torrents: torrents,
                maxAttempts: maxAttempts,
                request: request,
                coordinator: coordinator,
                appServices: appServices,
                playerState: playerState
            )
        }
    }

    private func runSingleAttempt(
        torrent: TorrentResult,
        request: PersistentPlaybackStartRequest,
        coordinator: TorrentPlaybackCoordinator,
        appServices: AppServices,
        playerState: PlayerState
    ) async {
        guard !Task.isCancelled else { return }

        if let localPath = appServices.resolvedCompletedMediaPath(for: torrent) {
            await appServices.prepareForLocalFilePlayback()
            let localURL = URL(fileURLWithPath: localPath)
            PlaybackLog.log("runSingleAttempt -> playing local downloaded file: \(localPath)")
            PlaybackLog.log("[MKVHLS] persistent single completed file hash=\(torrent.resolvedInfoHash ?? "?") ext=\(localURL.pathExtension.lowercased()) exists=\(FileManager.default.fileExists(atPath: localURL.path))")
            phase = .openingPlayer
            coordinator.playLocalFile(
                localFilePath: localPath,
                torrent: torrent,
                allTorrents: request.allTorrents,
                playerState: playerState,
                movieId: request.movieId,
                subtitleURL: request.subtitleURL,
                subtitleAppearance: request.playback.appearance,
                subtitleFontSize: request.playback.fontSize,
                episodeTitle: request.episodeTitle,
                displayTitle: request.displayTitle,
                resumePosition: request.resumePosition,
                knownDurationSeconds: request.knownDurationSeconds,
                posterURL: request.posterURL
            )
            applySubtitlePlayback(
                request: request,
                playerState: playerState,
                localMediaPath: localPath
            )
            playerState.isStreamingTorrent = true
            request.onPlaybackOpened?(torrent)
            scheduleShellReleaseWhenPlayerOpens(playerState: playerState)
            return
        }

        let session = await coordinator.startSession(for: torrent)
        appServices.registerActiveSession(session)
        appServices.trackStreamForCleanup(torrent: torrent, movieId: request.movieId)
        request.onSessionStarted?(session)
        startMonitoring(session: session)

        await session.waitForPlayback(timeout: request.waitTimeout)
        stopMonitoring()

        guard !Task.isCancelled else { return }

        if case .failed(let message) = session.state {
            phase = .failed(message)
            await appServices.cancelActiveStreamWithoutPersistentReset()
            return
        }
        guard case .ready = session.state else {
            phase = .failed("Stream did not become ready.")
            await appServices.cancelActiveStreamWithoutPersistentReset()
            return
        }

        await openPlayer(
            torrent: torrent,
            request: request,
            session: session,
            coordinator: coordinator,
            playerState: playerState
        )
    }

    private func runBestAvailableAttempts(
        torrents: [TorrentResult],
        maxAttempts: Int,
        request: PersistentPlaybackStartRequest,
        coordinator: TorrentPlaybackCoordinator,
        appServices: AppServices,
        playerState: PlayerState
    ) async {
        let ordered = PersistentPlaybackStartRequest.orderedCandidates(from: torrents)
        var lastError: String?
        var attempt = 0

        for torrent in ordered.prefix(maxAttempts) {
            guard !Task.isCancelled else { return }

            attempt += 1
            await coordinator.cancel()
            stopMonitoring()

            item = PersistentPlaybackItem.make(request: request, torrent: torrent)
            activeTorrentID = torrent.id
            phase = .preparing

            if let localPath = appServices.resolvedCompletedMediaPath(for: torrent) {
                await appServices.prepareForLocalFilePlayback()
                let localURL = URL(fileURLWithPath: localPath)
                PlaybackLog.log("runBestAvailableAttempts -> playing local downloaded file: \(localPath)")
                PlaybackLog.log("[MKVHLS] persistent best completed file hash=\(torrent.resolvedInfoHash ?? "?") ext=\(localURL.pathExtension.lowercased()) exists=\(FileManager.default.fileExists(atPath: localURL.path)) attempt=\(attempt)")
                phase = .openingPlayer
                coordinator.playLocalFile(
                    localFilePath: localPath,
                    torrent: torrent,
                    allTorrents: request.allTorrents,
                    playerState: playerState,
                    movieId: request.movieId,
                    subtitleURL: request.subtitleURL,
                    subtitleAppearance: request.playback.appearance,
                    subtitleFontSize: request.playback.fontSize,
                    episodeTitle: request.episodeTitle,
                    displayTitle: request.displayTitle,
                    resumePosition: request.resumePosition,
                    knownDurationSeconds: request.knownDurationSeconds,
                    posterURL: request.posterURL
                )
                applySubtitlePlayback(
                    request: request,
                    playerState: playerState,
                    localMediaPath: localPath
                )
                playerState.isStreamingTorrent = true
                request.onPlaybackOpened?(torrent)
                scheduleShellReleaseWhenPlayerOpens(playerState: playerState)
                return
            }

            PlaybackLog.log(
                "persistent attempt \(attempt)/\(min(maxAttempts, ordered.count)) — \"\(torrent.title)\" \(torrent.quality.rawValue)"
            )

            let session = await coordinator.startSession(for: torrent)
            appServices.registerActiveSession(session)
            appServices.trackStreamForCleanup(torrent: torrent, movieId: request.movieId)
            request.onSessionStarted?(session)
            startMonitoring(session: session)

            await session.waitForPlayback(timeout: request.waitTimeout)
            stopMonitoring()

            guard !Task.isCancelled else { return }

            if case .failed(let err) = session.state {
                lastError = err
                continue
            }
            guard case .ready = session.state else {
                lastError = "Stream did not become ready."
                continue
            }

            await openPlayer(
                torrent: torrent,
                request: request,
                session: session,
                coordinator: coordinator,
                playerState: playerState
            )
            return
        }

        let summary = lastError ?? "Could not prepare any release for streaming. Try another version."
        phase = .failed(summary)
        await appServices.cancelActiveStreamWithoutPersistentReset()
    }

    private func openPlayer(
        torrent: TorrentResult,
        request: PersistentPlaybackStartRequest,
        session: TorrentStreamSession,
        coordinator: TorrentPlaybackCoordinator,
        playerState: PlayerState
    ) async {
        phase = .openingPlayer
        do {
            try await coordinator.finishPlayback(
                torrent: torrent,
                allTorrents: request.allTorrents,
                session: session,
                playerState: playerState,
                movieId: request.movieId,
                subtitleURL: request.subtitleURL,
                subtitleAppearance: request.playback.appearance,
                subtitleFontSize: request.playback.fontSize,
                episodeTitle: request.episodeTitle,
                displayTitle: request.displayTitle,
                resumePosition: request.resumePosition,
                knownDurationSeconds: request.knownDurationSeconds,
                posterURL: request.posterURL
            )
            applySubtitlePlayback(
                request: request,
                playerState: playerState,
                session: session
            )
            playerState.isStreamingTorrent = true
            request.onPlaybackOpened?(torrent)
            scheduleShellReleaseWhenPlayerOpens(playerState: playerState)
        } catch {
            PlaybackLog.log("[MKVHLS] openPlayer failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            await session.cancel()
        }
    }

    private func applySubtitlePlayback(
        request: PersistentPlaybackStartRequest,
        playerState: PlayerState,
        session: TorrentStreamSession? = nil,
        localMediaPath: String? = nil
    ) {
        SubtitlePlaybackSupport.attachToPlayback(
            playerState: playerState,
            catalog: request.subtitleCatalog,
            searchContext: request.subtitleSearchContext,
            selectedSubtitleID: request.selectedSubtitleID,
            localMediaPath: localMediaPath,
            session: session,
            autoSelectRemote: false
        )
    }

    /// Keeps the bottom pill + row progress alive until AVPlayer is actually presented.
    private func scheduleShellReleaseWhenPlayerOpens(playerState: PlayerState) {
        pipelineTask = nil
        Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(180)
            while ContinuousClock.now < deadline {
                if playerState.isPresented {
                    activeTorrentID = nil
                    item = nil
                    phase = .idle
                    phaseLabel = ""
                    phaseDetail = ""
                    publishUITick(.inactive)
                    monitorTask?.cancel()
                    monitorTask = nil
                    return
                }
                if case .failed = phase {
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func startMonitoring(session: TorrentStreamSession) {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor in
            while !Task.isCancelled {
                await Task.yield()

                let snapshot: TorrentRowBufferingSnapshot
                if let metrics = session.rowMetrics {
                    snapshot = TorrentRowBufferingSnapshot(metrics: metrics)
                } else {
                    snapshot = await session.rowBufferingSnapshot()
                }

                switch session.state {
                case .ready:
                    phase = .openingPlayer
                    publishUI(from: snapshot, session: session)
                    return
                case .failed(let message):
                    phase = .failed(message)
                    publishUI(from: snapshot, session: session, failedMessage: message)
                    return
                case .cancelled:
                    phase = .idle
                    publishUITick(.inactive)
                    return
                case .preparing:
                    updatePhaseIfNeeded(.preparing, snapshot: snapshot)
                    publishUI(from: snapshot, session: session)
                case .buffering:
                    if case .buffering = phase {} else {
                        phase = .buffering(progress: snapshot.progress, statusLine: snapshot.statusLine)
                    }
                    publishUI(from: snapshot, session: session)
                case .idle:
                    updatePhaseIfNeeded(.preparing, snapshot: snapshot)
                    publishUI(from: snapshot, session: session)
                }

                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }

    private func updatePhaseIfNeeded(_ newPhase: PersistentPlaybackPhase, snapshot: TorrentRowBufferingSnapshot) {
        guard phase != newPhase else { return }
        phase = newPhase
        phaseLabel = snapshot.phase
        phaseDetail = snapshot.detail
    }

    private func publishUI(
        from snapshot: TorrentRowBufferingSnapshot,
        session: TorrentStreamSession,
        failedMessage: String? = nil
    ) {
        _ = session
        let rawPercent = Int(min(100, max(0, snapshot.progress * 100)).rounded())
        let progressPercent = (rawPercent / 4) * 4
        let phaseText = failedMessage == nil ? snapshot.phase : "Failed"
        let detailLine = throttledRowDetail(
            fresh: failedMessage ?? snapshot.detail,
            phase: phaseText
        )
        let tick = PersistentPlaybackUITick(
            movieId: item?.movieId,
            torrentId: activeTorrentID,
            progressPercent: progressPercent,
            phaseLabel: phaseText,
            phaseDetail: detailLine,
            statusLine: phaseText,
            rowPhase: phaseText,
            rowDetail: detailLine,
            isActive: isActive
        )
        publishUITick(tick)
    }

    private func throttledRowDetail(fresh: String, phase: String) -> String {
        let now = ContinuousClock.now
        if phase != lastPublishedTick.rowPhase || failedPhase(phase) {
            lastPublishedDetailLine = fresh
            lastDetailPublishTime = now
            return fresh
        }
        if let last = lastDetailPublishTime, now - last < Self.detailPublishMinInterval {
            return lastPublishedDetailLine
        }
        lastPublishedDetailLine = fresh
        lastDetailPublishTime = now
        return fresh
    }

    private func failedPhase(_ phase: String) -> Bool {
        phase == "Failed"
    }

    private func statusLineForPublish(
        snapshot: TorrentRowBufferingSnapshot,
        failedMessage: String?
    ) -> String {
        if let failedMessage { return failedMessage }
        switch phase {
        case .preparing: return "Starting stream…"
        case .buffering(_, let line): return line
        case .openingPlayer: return "Opening player…"
        case .failed(let message): return message
        case .idle: return ""
        }
    }

    private func publishUITick(_ tick: PersistentPlaybackUITick) {
        guard tick != lastPublishedTick else { return }
        lastPublishedTick = tick
        uiTick = tick
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Awaits until playback opens, fails, or is cancelled.
    public func waitUntilSettled() async throws {
        while !Task.isCancelled {
            switch phase {
            case .idle, .openingPlayer:
                return
            case .failed(let message):
                throw TorrentPlaybackError.streamingFailed(message)
            case .preparing, .buffering:
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
