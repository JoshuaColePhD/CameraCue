import AVFoundation
import Foundation
import CoreMedia

/// Core Audio can reuse tap storage immediately. Copies own their bytes and are
/// never mutated after submission; only this narrow transfer is unchecked.
public final class OwnedSpeechBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    public init(copying source: AVAudioPCMBuffer) throws {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { throw SpeechSessionError.audioFormat }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in from.indices {
            guard index < to.count, from[index].mDataByteSize <= to[index].mDataByteSize, let input = from[index].mData, let output = to[index].mData else { throw SpeechSessionError.audioFormat }
            memcpy(output, input, Int(from[index].mDataByteSize))
            to[index].mDataByteSize = from[index].mDataByteSize
        }
        buffer = copy
    }
}
public enum SpeechSessionError: Error, LocalizedError, Sendable {
    case unsupported, assetsMissing, audioFormat, backlog, permissionNeeded, cancelled, timeout
    public var errorDescription: String? {
        switch self {
        case .unsupported: "This speech engine is unavailable on this Mac or for this language."
        case .assetsMissing: "Install the on-device speech model before using this engine."
        case .audioFormat: "The audio format could not be prepared for speech recognition."
        case .backlog: "Audio processing fell behind. Your reading position is preserved."
        case .permissionNeeded: "Allow Speech Recognition for CameraCue before evaluating the legacy recognizer."
        case .cancelled: "Speech analysis was cancelled."
        case .timeout: "Speech recognition did not finish in time."
        }
    }
}
