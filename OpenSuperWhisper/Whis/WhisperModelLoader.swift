//
// Created by user on 07.02.2025.
//

import Foundation

public struct WhisperModelLoader {
    public var context: UnsafeMutableRawPointer?
    public var read: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int) -> Int)?
    public var eof: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)?
    public var close: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?

    public init(context: UnsafeMutableRawPointer? = nil, read: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int) -> Int)? = nil, eof: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)? = nil, close: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil) {
        self.context = context
        self.read = read
        self.eof = eof
        self.close = close
    }

    func toC() -> whisper_model_loader {
        return whisper_model_loader(context: context,
                                    read: read,
                                    eof: eof,
                                    close: close)
    }
}