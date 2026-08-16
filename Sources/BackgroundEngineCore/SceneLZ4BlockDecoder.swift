import Foundation

public struct SceneLZ4BlockDecoder: Sendable {
    public init() {}

    public func decode(_ block: Data, expectedSize: Int, maxOutputSize: Int = 64 * 1024 * 1024) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maxOutputSize else {
            throw SceneTextureError.invalidLZ4Block
        }
        var inputOffset = 0
        var output: [UInt8] = []
        output.reserveCapacity(expectedSize)

        while inputOffset < block.count {
            let token = block[inputOffset]
            inputOffset += 1

            let literalLength = try readLength(
                initial: Int(token >> 4),
                block: block,
                offset: &inputOffset
            )
            guard block.count - inputOffset >= literalLength else {
                throw SceneTextureError.invalidLZ4Block
            }
            guard literalLength <= expectedSize - output.count else {
                throw SceneTextureError.invalidLZ4Block
            }
            output.append(contentsOf: block[inputOffset..<(inputOffset + literalLength)])
            inputOffset += literalLength

            if inputOffset == block.count {
                break
            }
            guard block.count - inputOffset >= 2 else {
                throw SceneTextureError.invalidLZ4Block
            }
            let matchOffset = Int(block[inputOffset]) | (Int(block[inputOffset + 1]) << 8)
            inputOffset += 2
            guard matchOffset > 0, matchOffset <= output.count else {
                throw SceneTextureError.invalidMatchOffset
            }

            let matchLength = try readLength(
                initial: Int(token & 0x0F),
                block: block,
                offset: &inputOffset
            ) + 4
            for _ in 0..<matchLength {
                guard output.count < expectedSize else {
                    throw SceneTextureError.invalidLZ4Block
                }
                let sourceIndex = output.count - matchOffset
                output.append(output[sourceIndex])
            }
        }

        guard output.count == expectedSize else {
            throw SceneTextureError.invalidLZ4Block
        }
        return Data(output)
    }

    private func readLength(initial: Int, block: Data, offset: inout Int) throws -> Int {
        var length = initial
        if initial == 15 {
            while true {
                guard offset < block.count else {
                    throw SceneTextureError.invalidLZ4Block
                }
                let byte = Int(block[offset])
                offset += 1
                length += byte
                if byte != 255 {
                    break
                }
            }
        }
        return length
    }
}
