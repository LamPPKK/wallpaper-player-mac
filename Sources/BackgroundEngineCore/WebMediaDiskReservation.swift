import Darwin
import Foundation

/// Process-wide accounting for temporary Web media files. Available-capacity
/// checks alone race when two display sessions start conversions together;
/// reservations make each job account for bytes the other job has not written
/// yet while retaining a fixed startup-disk safety margin.
final class WebMediaDiskReservationManager: @unchecked Sendable {
    static let shared = WebMediaDiskReservationManager()
    static let safetyReserveBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private var reservations: [UUID: UInt64] = [:]
    private let lock = NSLock()

    func acquire(directory: URL, bytes: UInt64) throws -> Token {
        let token = Token(id: UUID())
        try setReservation(
            token: token,
            directory: directory,
            bytes: bytes,
            requireExisting: false
        )
        return token
    }

    func resize(token: Token, directory: URL, bytes: UInt64) throws {
        try setReservation(
            token: token,
            directory: directory,
            bytes: bytes,
            requireExisting: true
        )
    }

    func release(_ token: Token) {
        lock.withLock { reservations[token.id] = nil }
    }

    func reservedBytesForTesting() -> UInt64 {
        lock.withLock { reservations.values.reduce(0, &+) }
    }

    private func setReservation(
        token: Token,
        directory: URL,
        bytes: UInt64,
        requireExisting: Bool
    ) throws {
        let available = try Self.availableBytes(at: directory)
        try lock.withLock {
            if requireExisting, reservations[token.id] == nil {
                throw WebMediaPreparationError.unsafeCacheDirectory
            }
            var otherReservations: UInt64 = 0
            var overflow = false
            for (identifier, value) in reservations where identifier != token.id {
                (otherReservations, overflow) = otherReservations.addingReportingOverflow(value)
                if overflow { break }
            }
            let (requiredWithoutReserve, reservationOverflow) = otherReservations
                .addingReportingOverflow(bytes)
            let (required, reserveOverflow) = requiredWithoutReserve
                .addingReportingOverflow(Self.safetyReserveBytes)
            guard !overflow, !reservationOverflow, !reserveOverflow, required <= available else {
                throw WebMediaPreparationError.insufficientDiskSpace(
                    required: overflow || reservationOverflow || reserveOverflow ? UInt64.max : required,
                    available: available
                )
            }
            reservations[token.id] = bytes
        }
    }

    static func availableBytes(at directory: URL) throws -> UInt64 {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        guard let available = usableAvailableBytes(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            basic: values.volumeAvailableCapacity.map(Int64.init)
        ) else {
            throw WebMediaPreparationError.unsafeCacheDirectory
        }
        return available
    }

    /// Some sandboxed and quota-managed volumes report zero for the
    /// "important usage" estimate while the ordinary capacity key still has
    /// a valid value. Treat that zero as unavailable metadata and fall back;
    /// preserve a real zero only when no better nonnegative estimate exists.
    static func usableAvailableBytes(
        importantUsage: Int64?,
        basic: Int64?
    ) -> UInt64? {
        if let importantUsage, importantUsage > 0 {
            return UInt64(importantUsage)
        }
        if let basic, basic >= 0 {
            return UInt64(basic)
        }
        if importantUsage == 0 {
            return 0
        }
        return nil
    }

    static func regularFileByteCount(
        at source: URL,
        maximumBytes: UInt64
    ) throws -> UInt64 {
        var attributes = stat()
        let status = source.standardizedFileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        guard status == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0 else {
            throw WebMediaPreparationError.unsafeSource(source.path)
        }
        let bytes = UInt64(attributes.st_size)
        guard bytes <= maximumBytes else {
            throw WebMediaPreparationError.sourceTooLarge(bytes, maximumBytes)
        }
        return bytes
    }
}
