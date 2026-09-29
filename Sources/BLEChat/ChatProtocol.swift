import Foundation
import CoreBluetooth

enum ChatProtocol {
    static let serviceUUID = CBUUID(string: "E20A39F4-73F5-4BC4-A12F-17D1AD07A961")
    static let rxCharacteristicUUID = CBUUID(string: "E20A39F4-73F5-4BC4-A12F-17D1AD07A962")
    static let txCharacteristicUUID = CBUUID(string: "E20A39F4-73F5-4BC4-A12F-17D1AD07A963")
}

/// Splits arbitrary UTF-8 text into BLE-sized frames and reassembles them.
///
/// Frame layout (big-endian):
///
///     [ messageID: UInt16 ][ sequence: UInt16 ][ total: UInt16 ][ payload ... ]
///
/// `maxPayload` is kept well below the ~185 byte negotiated ATT MTU so that a
/// single write/notification never gets truncated.
enum ChatFraming {
    static let headerSize = 6
    static let maxPayload = 150

    struct Frame {
        let messageID: UInt16
        let sequence: UInt16
        let total: UInt16
        let payload: Data
    }

    static func encode(messageID: UInt16, text: String) -> [Data] {
        let payload = Data(text.utf8)
        let total = max(1, (payload.count + maxPayload - 1) / maxPayload)

        var frames: [Data] = []
        frames.reserveCapacity(total)

        for sequence in 0..<total {
            let start = sequence * maxPayload
            let end = min(start + maxPayload, payload.count)
            let piece = start < end ? payload.subdata(in: start..<end) : Data()

            var data = Data(capacity: headerSize + piece.count)
            append(UInt16(messageID), to: &data)
            append(UInt16(sequence), to: &data)
            append(UInt16(total), to: &data)
            data.append(piece)
            frames.append(data)
        }

        return frames
    }

    static func decode(_ data: Data) -> Frame? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        let messageID = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let total = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        let payload = data.subdata(in: headerSize..<data.count)
        return Frame(messageID: messageID, sequence: sequence, total: total, payload: payload)
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}
