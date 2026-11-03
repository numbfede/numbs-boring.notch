//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    @Published var fullscreenStatus: [String: Bool] = [:]

    private var monitorTask: Task<Void, Never>?
    private var spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            // Deferred past init so the two shared singletons never initialize
            // each other. "Media apps only" also depends on what is playing and
            // on the setting, neither of which produces a space change.
            MusicManager.shared.$bundleIdentifier
                .removeDuplicates()
                .sink { [weak self] _ in
                    Task { @MainActor in self?.refreshStatus() }
                }
                .store(in: &cancellables)
            Defaults.publisher(.hideNotchOption)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.refreshStatus() }
                }
                .store(in: &cancellables)

            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                self.spaces = spaces
                refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        let option = Defaults[.hideNotchOption]
        let musicSource = MusicManager.shared.bundleIdentifier
        var newStatus: [String: Bool] = [:]

        for space in spaces {
            guard let uuid = space.screenUUID else { continue }
            let shouldHide: Bool
            if option == .nowPlayingOnly {
                // With no media source there is no media app to hide for.
                shouldHide = musicSource.map { space.runningApps.contains($0) } ?? false
            } else {
                shouldHide = true
            }
            // A screen can report several spaces: any match hides the notch.
            newStatus[uuid] = (newStatus[uuid] ?? false) || shouldHide
        }

        if newStatus != fullscreenStatus {
            fullscreenStatus = newStatus
        }
    }
}
