import Foundation

public enum Key: Equatable, Sendable {
    case up
    case down
    case left
    case right
    case enter
    case escape
    case tab
    case backspace
    case char(Character)
    case ctrlC
    case resize
    case none

    /// Parses the first key out of `bytes`.
    ///
    /// Returns `nil` when `bytes` holds only part of a key — a lone `ESC` that may still grow into a
    /// control sequence, a truncated CSI sequence, or an incomplete UTF-8 scalar. Callers keep those
    /// bytes buffered and append more input before parsing again.
    public static func parsePrefix(bytes: [UInt8]) -> (key: Key, consumed: Int)? {
        guard let first = bytes.first else { return nil }

        if first != 27 {
            if first < 0x80 {
                return (singleByteKey(first), 1)
            }
            let length = utf8SequenceLength(first)
            guard length > 1, bytes.count >= length else { return nil }
            let slice = Array(bytes[0..<length])
            if let character = String(bytes: slice, encoding: .utf8)?.first {
                return (.char(character), length)
            }
            return (.none, length)
        }

        // ESC: a lone ESC is ambiguous until we know no sequence continuation follows.
        guard bytes.count >= 2 else { return nil }

        if bytes[1] == 27 {
            return (.escape, 1)
        }
        guard bytes[1] == UInt8(ascii: "[") || bytes[1] == UInt8(ascii: "O") else {
            // ESC followed by a printable byte: treat as a standalone Escape key.
            return (.escape, 1)
        }
        guard bytes.count >= 3 else { return nil }

        if bytes[1] == UInt8(ascii: "O") {
            return (Self.key(forFinalByte: bytes[2]) ?? .none, 3)
        }

        // CSI: parameters run until a final byte in 0x40...0x7E.
        var index = 2
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x40 && byte <= 0x7E {
                return (Self.key(forFinalByte: byte) ?? .none, index + 1)
            }
            index += 1
        }
        return nil
    }

    private static func singleByteKey(_ byte: UInt8) -> Key {
        switch byte {
        case 3:
            return .ctrlC
        case 9:
            return .tab
        case 10, 13:
            return .enter
        case 27:
            return .escape
        case 127, 8:
            return .backspace
        case 32...126:
            return .char(Character(UnicodeScalar(byte)))
        default:
            return .none
        }
    }

    private static func key(forFinalByte byte: UInt8) -> Key? {
        switch byte {
        case UInt8(ascii: "A"):
            return .up
        case UInt8(ascii: "B"):
            return .down
        case UInt8(ascii: "C"):
            return .right
        case UInt8(ascii: "D"):
            return .left
        case UInt8(ascii: "Z"): // Shift-Tab
            return .tab
        default:
            return nil
        }
    }

    private static func utf8SequenceLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return 1
        }
    }
}
