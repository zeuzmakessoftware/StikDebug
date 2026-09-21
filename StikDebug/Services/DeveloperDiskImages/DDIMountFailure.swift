import Foundation

enum DDIMountFailure {
    static func needsNewImage(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("badbuildmanifest")
            || message.contains("no matching build identity")
            || message.contains("no matching identity")
    }

    static func recoveryMessage(for details: String) -> String {
        guard needsNewImage(details) else { return details }
        return """
        This developer disk image does not contain a usable build identity for your device.

        Install the latest build of this fork, or use Settings → Advanced → Import DDI Folder to select a personalized image exported from the latest Xcode. iOS 27 and new iPhone models may require an image newer than the download mirror provides.

        Details: \(details)
        """
    }
}
