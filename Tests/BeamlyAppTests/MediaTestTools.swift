import Foundation
import BeamlyCore

func mediaTestTools() -> FFmpegTools {
    let environment = ProcessInfo.processInfo.environment
    let bundle = environment["BEAMLY_TEST_APP_BUNDLE"].flatMap { Bundle(url: URL(fileURLWithPath: $0)) } ?? .main
    return FFmpegTools(customDirectory: environment["BEAMLY_TEST_TOOLS_DIRECTORY"].map { URL(fileURLWithPath: $0) }, bundle: bundle)
}
