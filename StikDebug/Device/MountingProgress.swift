//
//  MountingProgress.swift
//  StikDebug
//

import Foundation
import idevice

final class MountingProgress: ObservableObject {
    static let shared = MountingProgress()

    @Published private(set) var mountProgress: Double = 0.0
    @Published private(set) var isMounting = false
    @Published private(set) var coolisMounted: Bool = false

    private let mountCheckLock = NSLock()
    private var mountCheckInProgress = false

    private init() {}

    func checkforMounted() {
        guard TunnelManager.shared.isConnected else { return }

        mountCheckLock.lock()
        guard !mountCheckInProgress else {
            mountCheckLock.unlock()
            return
        }
        mountCheckInProgress = true
        mountCheckLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let mounted = isMounted()

            self.mountCheckLock.lock()
            self.mountCheckInProgress = false
            self.mountCheckLock.unlock()

            DispatchQueue.main.async {
                self.coolisMounted = mounted
            }
        }
    }

    func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
        let percentage = Double(progress) / Double(total) * 100.0
        DispatchQueue.main.async {
            self.mountProgress = percentage
        }
    }

    func pubMount() {
        Task { @MainActor in
            guard TunnelManager.shared.isConnected, !isMounting, !coolisMounted else { return }
            isMounting = true
            mountProgress = 0
            defer { isMounting = false }
            do {
                let directory = try await DeveloperDiskImageService.shared.prepare()
                guard TunnelManager.shared.isConnected else { return }
                var mountError = await Self.mount(directory)
                if let error = mountError, DDIMountFailure.needsNewImage(error) {
                    do {
                        let refreshed = try await DeveloperDiskImageService.shared.refreshAfterMountFailure()
                        if refreshed != directory, TunnelManager.shared.isConnected {
                            mountProgress = 0
                            mountError = await Self.mount(refreshed)
                        }
                    } catch {
                        mountError = "\(mountError ?? "")\nImage update failed: \(error.localizedDescription)"
                    }
                }
                if let mountError {
                    showAlert(title: "DDI Mount Failed", message: DDIMountFailure.recoveryMessage(for: mountError), showOk: true, showTryAgain: true) { shouldTryAgain in
                        if shouldTryAgain {
                            self.pubMount()
                        }
                    }
                } else {
                    self.coolisMounted = true
                    self.checkforMounted()
                }
            } catch {
                showAlert(title: "DDI Unavailable", message: error.localizedDescription, showOk: true)
            }
        }
    }

    private static func mount(_ directory: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard isPairing() else { return "Import a valid pairing file before mounting a DDI." }
            if isMounted() { return nil as String? }
            return mountPersonalDDI(
                imagePath: directory.appendingPathComponent("Image.dmg").path,
                trustcachePath: directory.appendingPathComponent("Image.dmg.trustcache").path,
                manifestPath: directory.appendingPathComponent("BuildManifest.plist").path
            )
        }.value
    }
}

func isPairing() -> Bool {
    let pairingPath = PairingFileStore.prepareURL().path
    var pairingFile: RpPairingFileHandle?
    let error = rp_pairing_file_read(pairingPath, &pairingFile)
    if error != nil {
        return false
    }
    rp_pairing_file_free(pairingFile)
    return true
}
