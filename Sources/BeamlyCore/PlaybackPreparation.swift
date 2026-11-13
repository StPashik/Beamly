import Darwin
import Foundation

public enum PlaybackPreparationStage: String, CaseIterable, Sendable {
    case readingFile = "Reading video information…"
    case originalStream = "Preparing video without conversion…"
    case systemEncoding = "Preparing video with the system encoder…"
    case softwareEncoding = "Preparing video with the software encoder…"
    case subtitles = "Preparing subtitles…"
    case loadingPlayer = "Loading video…"
    case softwareFallback = "Retrying with the software encoder…"
}

public enum MediaPipelineError: LocalizedError {
    case missingTool(String)
    case invalidMedia(String)
    case processFailed(String, String)
    case insufficientSpace
    case timedOut

    public static func isInsufficientSpace(_ error: Error) -> Bool {
        if case .insufficientSpace? = error as? Self { return true }
        var cause = error as NSError
        for _ in 0..<4 {
            if (cause.domain == NSPOSIXErrorDomain && cause.code == Int(ENOSPC))
                || (cause.domain == NSCocoaErrorDomain && cause.code == CocoaError.fileWriteOutOfSpace.rawValue) { return true }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            cause = underlying
        }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return String(format: NSLocalizedString("%@ is missing. Reinstall Beamly or choose a custom FFmpeg folder in Settings.", comment: ""), name)
        case .invalidMedia(let message): return message
        case .processFailed(let name, let message): return "\(name): \(message)"
        case .insufficientSpace: return NSLocalizedString("Not enough space for the video buffer. Free up disk space and try again.", comment: "")
        case .timedOut: return NSLocalizedString("Video preparation made no progress for 90 seconds. Try software encoding.", comment: "")
        }
    }
}
