import Darwin
import BackgroundEngineCore
import Foundation
import Security

/// A per-WebView HTTP origin for local Web wallpapers.
///
/// WebKit intentionally does not route every `HTMLMediaElement` request
/// through `WKURLSchemeHandler`. Serving the imported project from an
/// ephemeral IPv4 loopback listener gives media the normal HTTP byte-range
/// semantics it expects without exposing the project to the LAN. Every URL
/// also carries a random 256-bit session token, so another local process
/// cannot guess a wallpaper's resource URLs.
final class WebProjectLoopbackServer: @unchecked Sendable {
    static let preparedVideoAliasSuffix = ".__background_engine_prepared.mp4"
    static let preparedAudioAliasSuffix = ".__background_engine_prepared.m4a"
    static let preparedRoutePathComponent = "__background_engine_prepared"
    private static let maximumHeaderBytes = 32 * 1_024
    private static let maximumRequestTargetBytes = 4 * 1_024
    private static let maximumHeaderLineBytes = 8 * 1_024
    private static let maximumHeaderCount = 64
    private static let maximumActiveConnections = 64
    private static let responseChunkBytes = 256 * 1_024
    private static let defaultHeaderTimeout: TimeInterval = 3
    private static let defaultResponseIdleTimeout: TimeInterval = 30

    /// A monotonic deadline that can be renewed after observable I/O progress.
    /// Request-header readers intentionally never renew it, preserving their
    /// absolute slow-drip limit. Response writers renew it after every
    /// successful `send`, so the timeout measures a stalled peer rather than
    /// the total duration of a large response.
    private final class RenewableMonotonicDeadline {
        private let timeoutNanoseconds: UInt64
        private(set) var nanoseconds: UInt64 = 0

        init(timeoutNanoseconds: UInt64) {
            self.timeoutNanoseconds = timeoutNanoseconds
            resetAfterProgress()
        }

        func resetAfterProgress() {
            let now = WebProjectLoopbackServer.monotonicNanoseconds()
            nanoseconds = now.addingReportingOverflow(timeoutNanoseconds).overflow
                ? UInt64.max
                : now + timeoutNanoseconds
        }

        var pollTimeoutMilliseconds: Int32? {
            let now = WebProjectLoopbackServer.monotonicNanoseconds()
            guard now < nanoseconds else { return nil }
            let remaining = nanoseconds - now
            let roundedUpMilliseconds = (remaining + 999_999) / 1_000_000
            return Int32(min(max(roundedUpMilliseconds, 1), UInt64(Int32.max)))
        }
    }

    private final class PinnedPreparedResource: @unchecked Sendable {
        let mimeType: String
        private let descriptor: Int32

        init(url: URL, mimeType: String) throws {
            guard url.isFileURL,
                  WebProjectLoopbackServer.isSafeHeaderValue(mimeType) else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let canonicalPath = url.withUnsafeFileSystemRepresentation { path -> String? in
                guard let path, realpath(path, &canonicalBuffer) != nil else { return nil }
                return String(
                    decoding: canonicalBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
            }
            guard let canonicalPath, canonicalPath.hasPrefix("/") else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            let components = canonicalPath.split(separator: "/").map(String.init)
            guard !components.isEmpty else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            var expected = stat()
            let inspected = canonicalPath.withCString { lstat($0, &expected) }
            guard inspected == 0, (expected.st_mode & S_IFMT) == S_IFREG else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            var current = open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY)
            guard current >= 0 else { throw WebProjectResourceError.unsafeLocalFile }
            for (index, component) in components.enumerated() {
                let final = index == components.count - 1
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (final ? 0 : O_DIRECTORY)
                let next = component.withCString { openat(current, $0, flags) }
                close(current)
                guard next >= 0 else {
                    throw WebProjectResourceError.unsafeLocalFile
                }
                current = next
            }
            var actual = stat()
            guard fstat(current, &actual) == 0,
                  (actual.st_mode & S_IFMT) == S_IFREG,
                  actual.st_dev == expected.st_dev,
                  actual.st_ino == expected.st_ino,
                  actual.st_size == expected.st_size else {
                close(current)
                throw WebProjectResourceError.unsafeLocalFile
            }
            self.mimeType = mimeType
            descriptor = current
        }

        deinit { close(descriptor) }

        func duplicateDescriptor() -> Int32? {
            let result = dup(descriptor)
            return result >= 0 ? result : nil
        }
    }

    private final class Connection: @unchecked Sendable {
        let identifier = UUID()
        private let lock = NSLock()
        private var descriptor: Int32
        private var isHandling = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit { finishHandling() }

        /// Grants the request worker sole close ownership. Stop may call
        /// `shutdown` concurrently, but the descriptor remains allocated until
        /// that worker calls `finishHandling`, so its numeric value cannot be
        /// recycled underneath poll/recv/send.
        func beginHandling() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0, !isHandling else { return nil }
            isHandling = true
            return descriptor
        }

        /// Interrupts active I/O without waiting for its syscall lock. A queued
        /// connection with no worker lease is closed immediately.
        func requestShutdown() {
            lock.lock()
            let current = descriptor
            if current >= 0 { _ = shutdown(current, SHUT_RDWR) }
            let closeImmediately = current >= 0 && !isHandling
            if closeImmediately { descriptor = -1 }
            lock.unlock()
            if closeImmediately { close(current) }
        }

        func finishHandling() {
            lock.lock()
            let current = descriptor
            descriptor = -1
            isHandling = false
            lock.unlock()
            guard current >= 0 else { return }
            _ = shutdown(current, SHUT_RDWR)
            close(current)
        }
    }

    private struct Request {
        let method: String
        let target: String
        let range: String?
        var isHead: Bool { method == "HEAD" }
    }

    private struct OpenResource {
        let descriptor: Int32
        let mimeType: String
    }

    private struct StopPlan: @unchecked Sendable {
        let listener: Int32
        let source: DispatchSourceRead?
        let activeConnections: [Connection]
    }

    let token: String
    let port: UInt16
    let networkAccessAllowed: Bool

    private let stateLock = NSLock()
    private var resolver: WebProjectResourceResolver
    private let projectRootDescriptor: Int32
    private var preparedBySourcePath = [String: PinnedPreparedResource]()
    private var listenerDescriptor: Int32
    private var listenerSource: DispatchSourceRead?
    private var connections = [UUID: Connection]()
    private var isStopped = false
    private let requestHeaderTimeoutNanoseconds: UInt64
    private let responseIdleTimeoutNanoseconds: UInt64
    private let responseSocketSendBufferBytes: Int32?
    private let acceptQueue = DispatchQueue(
        label: "com.lamppkk.backgroundengine.web-loopback.accept",
        qos: .userInitiated
    )
    private let acceptQueueKey = DispatchSpecificKey<UInt8>()
    private let stopDrainGroup = DispatchGroup()
    private let stopDrainQueue = DispatchQueue(
        label: "com.lamppkk.backgroundengine.web-loopback.stop",
        qos: .userInitiated
    )
    private let workerQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.lamppkk.backgroundengine.web-loopback.requests"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 8
        return queue
    }()

    init(
        projectRoot: URL,
        networkAccessAllowed: Bool,
        requestHeaderTimeout: TimeInterval = WebProjectLoopbackServer.defaultHeaderTimeout,
        responseTimeout: TimeInterval = WebProjectLoopbackServer.defaultResponseIdleTimeout,
        responseSocketSendBufferBytes: Int32? = nil
    ) throws {
        token = try Self.makeSessionToken()
        self.networkAccessAllowed = networkAccessAllowed
        guard let requestTimeout = Self.timeoutNanoseconds(requestHeaderTimeout),
              let responseTimeout = Self.timeoutNanoseconds(responseTimeout) else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        requestHeaderTimeoutNanoseconds = requestTimeout
        responseIdleTimeoutNanoseconds = responseTimeout
        guard responseSocketSendBufferBytes.map({ $0 > 0 && $0 <= 1_048_576 }) ?? true else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        self.responseSocketSendBufferBytes = responseSocketSendBufferBytes
        let initialResolver = try WebProjectResourceResolver(projectRoot: projectRoot)
        let rootDescriptor = open(
            initialResolver.projectRoot.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        var rootMetadata = stat()
        guard rootDescriptor >= 0,
              fstat(rootDescriptor, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            if rootDescriptor >= 0 { close(rootDescriptor) }
            throw WebProjectResourceError.invalidProjectRoot
        }

        let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listener >= 0 else {
            close(rootDescriptor)
            throw WebProjectResourceError.invalidVirtualURL
        }
        var reuseAddress: Int32 = 1
        _ = setsockopt(
            listener,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(listener, 64) == 0 else {
            close(listener)
            close(rootDescriptor)
            throw WebProjectResourceError.invalidVirtualURL
        }
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &boundLength)
            }
        }
        let boundPort = UInt16(bigEndian: boundAddress.sin_port)
        guard nameResult == 0,
              boundAddress.sin_family == sa_family_t(AF_INET),
              boundAddress.sin_addr.s_addr == inet_addr("127.0.0.1"),
              boundPort > 0 else {
            close(listener)
            close(rootDescriptor)
            throw WebProjectResourceError.invalidVirtualURL
        }
        let currentFlags = fcntl(listener, F_GETFL)
        guard currentFlags >= 0,
              fcntl(listener, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            close(listener)
            close(rootDescriptor)
            throw WebProjectResourceError.invalidVirtualURL
        }

        resolver = initialResolver
        projectRootDescriptor = rootDescriptor
        listenerDescriptor = listener
        port = boundPort

        let source = DispatchSource.makeReadSource(
            fileDescriptor: listener,
            queue: acceptQueue
        )
        listenerSource = source
        acceptQueue.setSpecific(key: acceptQueueKey, value: 1)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        // The dispatch source owns the listener descriptor after resume. Its
        // serial cancel handler is the only place that closes it, eliminating
        // a stop/event race where a recycled descriptor could reach accept().
        source.setCancelHandler { close(listener) }
        source.resume()
    }

    deinit {
        // Normal view teardown starts an asynchronous drain, whose closure
        // retains the server until every worker exits. This is only a fail-safe
        // for an owner that never requested teardown; it must not wait because
        // deinit can run on a request worker.
        if let plan = beginStopping() {
            initiateStop(plan)
            stopDrainGroup.leave()
        }
        close(projectRootDescriptor)
    }

    var originURL: URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/")!
    }

    func virtualURL(for localFile: URL) throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try loopbackURL(for: resolver.virtualURL(for: localFile))
    }

    func virtualDirectoryURL(for localDirectory: URL) throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try loopbackURL(for: resolver.virtualDirectoryURL(for: localDirectory))
    }

    func installPreparedResources(
        _ resources: [WebProjectPreparedResource],
        mimeTypeOverrides: [WebLocalResourceMIMEOverride]? = nil
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isStopped else { throw WebProjectResourceError.invalidVirtualURL }
        let updatedResolver = try resolver.replacingPreparedResources(
            resources,
            mimeTypeOverrides: mimeTypeOverrides
        )
        var pinned = [String: PinnedPreparedResource]()
        for resource in resources {
            let sourceURL = try updatedResolver.virtualURL(for: resource.sourceURL)
            let resolved = try updatedResolver.resolve(sourceURL)
            guard let sourcePath = resolved.preparedSourcePath else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            pinned[sourcePath] = try PinnedPreparedResource(
                url: resolved.fileURL,
                mimeType: resolved.mimeType
            )
        }
        resolver = updatedResolver
        preparedBySourcePath = pinned
    }

    /// Stops accepting, force-closes every active request, and waits for all
    /// request workers to release descriptors before returning.
    func stop() {
        if let plan = beginStopping() {
            drainStop(plan)
        } else {
            stopDrainGroup.wait()
        }
    }

    /// Starts the same deterministic drain without blocking the caller. View
    /// teardown invokes this from the main actor; the retained drain closure
    /// keeps the server alive until its listener and workers are fully reaped.
    func stopAsync() {
        guard let plan = beginStopping() else { return }
        stopDrainQueue.async { [self] in
            drainStop(plan)
        }
    }

    private func loopbackURL(for virtualURL: URL) throws -> URL {
        guard let virtualComponents = URLComponents(
            url: virtualURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.percentEncodedPath = "/\(token)" + virtualComponents.percentEncodedPath
        guard let result = components.url else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        return result
    }

    private func acceptPendingConnections() {
        while true {
            stateLock.lock()
            let listener = isStopped ? -1 : listenerDescriptor
            stateLock.unlock()
            guard listener >= 0 else { return }
            var peerAddress = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let accepted = withUnsafeMutablePointer(to: &peerAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listener, $0, &peerLength)
                }
            }
            if accepted < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            guard peerAddress.sin_family == sa_family_t(AF_INET),
                  peerAddress.sin_addr.s_addr == inet_addr("127.0.0.1") else {
                close(accepted)
                continue
            }
            var noSignal: Int32 = 1
            _ = setsockopt(
                accepted,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            if var sendBufferBytes = responseSocketSendBufferBytes,
               setsockopt(
                   accepted,
                   SOL_SOCKET,
                   SO_SNDBUF,
                   &sendBufferBytes,
                   socklen_t(MemoryLayout<Int32>.size)
               ) != 0 {
                close(accepted)
                continue
            }
            let connection = Connection(descriptor: accepted)
            stateLock.lock()
            guard !isStopped, connections.count < Self.maximumActiveConnections else {
                stateLock.unlock()
                connection.requestShutdown()
                continue
            }
            connections[connection.identifier] = connection
            stateLock.unlock()
            workerQueue.addOperation { [weak self, connection] in
                guard let descriptor = connection.beginHandling() else {
                    self?.finish(connection)
                    return
                }
                defer {
                    connection.finishHandling()
                    self?.finish(connection)
                }
                guard let self else { return }
                self.handle(descriptor: descriptor)
            }
        }
    }

    private func handle(descriptor: Int32) {
        guard let request = readRequest(from: descriptor) else {
            sendError(
                status: 400,
                reason: "Bad Request",
                methodIsHead: false,
                to: descriptor,
                deadline: RenewableMonotonicDeadline(
                    timeoutNanoseconds: responseIdleTimeoutNanoseconds
                )
            )
            return
        }
        let responseIdleDeadline = RenewableMonotonicDeadline(
            timeoutNanoseconds: responseIdleTimeoutNanoseconds
        )
        guard request.method == "GET" || request.method == "HEAD" else {
            sendError(
                status: 405,
                reason: "Method Not Allowed",
                methodIsHead: request.isHead,
                extraHeaders: ["Allow": "GET, HEAD"],
                to: descriptor,
                deadline: responseIdleDeadline
            )
            return
        }
        let resource: OpenResource
        do {
            resource = try openResource(target: request.target)
        } catch {
            sendError(
                status: 404,
                reason: "Not Found",
                methodIsHead: request.isHead,
                to: descriptor,
                deadline: responseIdleDeadline
            )
            return
        }
        defer { close(resource.descriptor) }
        var metadata = stat()
        guard fstat(resource.descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            sendError(
                status: 404,
                reason: "Not Found",
                methodIsHead: request.isHead,
                to: descriptor,
                deadline: responseIdleDeadline
            )
            return
        }
        let totalLength = UInt64(metadata.st_size)
        let byteRange: WebProjectByteRange
        do {
            byteRange = try WebProjectByteRange.resolve(
                header: request.range,
                totalLength: totalLength
            )
        } catch {
            sendError(
                status: 416,
                reason: "Range Not Satisfiable",
                methodIsHead: request.isHead,
                extraHeaders: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes */\(totalLength)"
                ],
                to: descriptor,
                deadline: responseIdleDeadline
            )
            return
        }
        let partial = request.range != nil
        var headers = securityHeaders()
        headers["Accept-Ranges"] = "bytes"
        headers["Content-Length"] = String(byteRange.length)
        headers["Content-Type"] = resource.mimeType
        if partial, byteRange.length > 0 {
            headers["Content-Range"] = "bytes \(byteRange.offset)-\(byteRange.offset + byteRange.length - 1)/\(totalLength)"
        }
        guard sendResponseHead(
            status: partial ? 206 : 200,
            reason: partial ? "Partial Content" : "OK",
            headers: headers,
            to: descriptor,
            deadline: responseIdleDeadline
        ), !request.isHead else { return }

        var remaining = byteRange.length
        var offset = byteRange.offset
        var buffer = [UInt8](repeating: 0, count: Self.responseChunkBytes)
        while remaining > 0 {
            let requested = min(UInt64(buffer.count), remaining)
            let count = pread(resource.descriptor, &buffer, Int(requested), off_t(offset))
            guard count > 0,
                  sendBytes(
                      buffer,
                      count: count,
                      to: descriptor,
                      deadline: responseIdleDeadline
                  ) else { return }
            remaining -= UInt64(count)
            offset += UInt64(count)
        }
    }

    private func readRequest(from descriptor: Int32) -> Request? {
        let deadline = RenewableMonotonicDeadline(
            timeoutNanoseconds: requestHeaderTimeoutNanoseconds
        )
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while data.count <= Self.maximumHeaderBytes {
            guard Self.waitUntilReady(
                descriptor: descriptor,
                events: Int16(POLLIN),
                deadline: deadline
            ) else { return nil }
            let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            if data.range(of: Data([13, 10, 13, 10])) != nil { break }
        }
        guard data.count <= Self.maximumHeaderBytes,
              let boundary = data.range(of: Data([13, 10, 13, 10])),
              boundary.upperBound == data.count,
              let headerText = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty,
              lines.count - 1 <= Self.maximumHeaderCount,
              lines.allSatisfy({ $0.utf8.count <= Self.maximumHeaderLineBytes }) else {
            return nil
        }
        let requestParts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3 else { return nil }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let version = requestParts[2]
        guard method.unicodeScalars.allSatisfy(Self.isHTTPTokenScalar),
              ["HTTP/1.0", "HTTP/1.1"].contains(version),
              target.hasPrefix("/"),
              target.utf8.count <= Self.maximumRequestTargetBytes,
              !target.contains("#"),
              !target.unicodeScalars.contains(where: Self.isUnsafeControlScalar) else {
            return nil
        }
        var headers = [String: [String]]()
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ", line.first != "\t",
                  let separator = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy(Self.isHTTPTokenScalar),
                  !value.unicodeScalars.contains(where: Self.isUnsafeHeaderScalar) else {
                return nil
            }
            headers[name.lowercased(), default: []].append(value)
        }
        guard headers["host"] == ["127.0.0.1:\(port)"],
              (headers["range"]?.count ?? 0) <= 1,
              (headers["content-length"]?.count ?? 0) <= 1,
              headers["transfer-encoding"] == nil,
              headers["content-length"]?.first.map({ $0 == "0" }) ?? true,
              (headers["range"]?.first?.utf8.count ?? 0) <= 256 else {
            return nil
        }
        return Request(method: method, target: target, range: headers["range"]?.first)
    }

    private func openResource(target: String) throws -> OpenResource {
        guard let components = URLComponents(
            string: "http://127.0.0.1:\(port)\(target)"
        ),
              components.scheme == "http",
              components.host == "127.0.0.1",
              components.port == Int(port),
              components.user == nil,
              components.password == nil else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        let parts = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard parts.count > 3,
              parts[0].isEmpty,
              parts[1] == Substring(token) else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        let preparedAliasKind: String?
        var resolvedParts: [Substring]
        if parts[2] == Substring(WebProjectResourceResolver.projectPathComponent) {
            preparedAliasKind = nil
            resolvedParts = Array(parts.dropFirst(2))
        } else if parts.count > 5,
                  parts[2] == Substring(Self.preparedRoutePathComponent),
                  parts[3] == "video" || parts[3] == "audio",
                  parts[4] == Substring(WebProjectResourceResolver.projectPathComponent) {
            preparedAliasKind = String(parts[3])
            resolvedParts = Array(parts.dropFirst(4))
        } else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        guard var finalPart = resolvedParts.last else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        if let preparedAliasKind {
            let suffix = preparedAliasKind == "video"
                ? Self.preparedVideoAliasSuffix
                : Self.preparedAudioAliasSuffix
            guard finalPart.hasSuffix(Substring(suffix)) else {
                throw WebProjectResourceError.invalidVirtualURL
            }
            finalPart.removeLast(suffix.count)
            resolvedParts[resolvedParts.count - 1] = finalPart
        }
        guard !finalPart.isEmpty else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        var virtualComponents = URLComponents()
        virtualComponents.scheme = WebProjectResourceResolver.scheme
        stateLock.lock()
        virtualComponents.host = resolver.sessionHost
        virtualComponents.percentEncodedPath = "/" + resolvedParts.joined(separator: "/")
        guard !isStopped, let virtualURL = virtualComponents.url else {
            stateLock.unlock()
            throw WebProjectResourceError.invalidVirtualURL
        }
        let resolved: WebProjectResolvedResource
        do {
            resolved = try resolver.resolve(virtualURL)
        } catch {
            stateLock.unlock()
            throw error
        }
        if let preparedAliasKind {
            guard resolved.preparedSourcePath != nil,
                  (preparedAliasKind == "video"
                      ? resolved.mimeType == "video/mp4"
                      : resolved.mimeType == "audio/mp4") else {
                stateLock.unlock()
                throw WebProjectResourceError.unsafeLocalFile
            }
        }
        let descriptor: Int32
        if let sourcePath = resolved.preparedSourcePath {
            descriptor = preparedBySourcePath[sourcePath]?.duplicateDescriptor() ?? -1
        } else if let pathComponents = resolved.projectRelativePathComponents {
            descriptor = openProjectResource(pathComponents: pathComponents)
        } else {
            descriptor = -1
        }
        stateLock.unlock()
        guard descriptor >= 0 else { throw WebProjectResourceError.unsafeLocalFile }
        return OpenResource(descriptor: descriptor, mimeType: resolved.mimeType)
    }

    /// Called only while `stateLock` is held, which keeps the root descriptor
    /// alive and makes replacement of prepared mappings atomic with opens.
    private func openProjectResource(pathComponents: [String]) -> Int32 {
        guard !pathComponents.isEmpty else { return -1 }
        var current = dup(projectRootDescriptor)
        guard current >= 0 else { return -1 }
        for (index, component) in pathComponents.enumerated() {
            let final = index == pathComponents.count - 1
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (final ? 0 : O_DIRECTORY)
            let next = component.withCString { openat(current, $0, flags) }
            close(current)
            guard next >= 0 else { return -1 }
            current = next
        }
        var metadata = stat()
        guard fstat(current, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            close(current)
            return -1
        }
        return current
    }

    private func securityHeaders() -> [String: String] {
        var headers = [
            "Cache-Control": "no-store",
            "Connection": "close",
            "Cross-Origin-Resource-Policy": "same-origin",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff"
        ]
        if !networkAccessAllowed {
            headers["Content-Security-Policy"] = [
                "default-src 'self' data: blob:",
                "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:",
                "style-src 'self' 'unsafe-inline' data: blob:",
                "img-src 'self' data: blob:",
                "media-src 'self' data: blob:",
                "font-src 'self' data:",
                "connect-src 'self'",
                "frame-src 'self' data: blob:",
                "worker-src 'self' blob:",
                "object-src 'none'",
                "base-uri 'self'",
                "form-action 'none'"
            ].joined(separator: "; ")
        }
        return headers
    }

    private func sendError(
        status: Int,
        reason: String,
        methodIsHead: Bool,
        extraHeaders: [String: String] = [:],
        to descriptor: Int32,
        deadline: RenewableMonotonicDeadline
    ) {
        let body = Data("\(status) \(reason)\n".utf8)
        var headers = securityHeaders()
        headers["Content-Length"] = String(body.count)
        headers["Content-Type"] = "text/plain; charset=utf-8"
        for (name, value) in extraHeaders { headers[name] = value }
        guard sendResponseHead(
            status: status,
            reason: reason,
            headers: headers,
            to: descriptor,
            deadline: deadline
        ),
              !methodIsHead else { return }
        _ = sendData(body, to: descriptor, deadline: deadline)
    }

    private func sendResponseHead(
        status: Int,
        reason: String,
        headers: [String: String],
        to descriptor: Int32,
        deadline: RenewableMonotonicDeadline
    ) -> Bool {
        guard headers.allSatisfy({
            $0.key.unicodeScalars.allSatisfy(Self.isHTTPTokenScalar)
                && Self.isSafeHeaderValue($0.value)
        }) else { return false }
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"
        return sendData(Data(response.utf8), to: descriptor, deadline: deadline)
    }

    private func sendData(
        _ data: Data,
        to descriptor: Int32,
        deadline: RenewableMonotonicDeadline
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            return sendBuffer(
                base,
                count: data.count,
                to: descriptor,
                deadline: deadline
            )
        }
    }

    private func sendBytes(
        _ bytes: [UInt8],
        count: Int,
        to descriptor: Int32,
        deadline: RenewableMonotonicDeadline
    ) -> Bool {
        bytes.withUnsafeBytes { storage in
            guard let base = storage.baseAddress else { return count == 0 }
            return sendBuffer(
                base,
                count: count,
                to: descriptor,
                deadline: deadline
            )
        }
    }

    private func sendBuffer(
        _ base: UnsafeRawPointer,
        count: Int,
        to descriptor: Int32,
        deadline: RenewableMonotonicDeadline
    ) -> Bool {
        var sent = 0
        while sent < count {
            guard Self.waitUntilReady(
                descriptor: descriptor,
                events: Int16(POLLOUT),
                deadline: deadline
            ) else { return false }
            let result = Darwin.send(
                descriptor,
                base.advanced(by: sent),
                count - sent,
                MSG_DONTWAIT
            )
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard result > 0 else { return false }
            sent += result
            deadline.resetAfterProgress()
        }
        return true
    }

    private func finish(_ connection: Connection) {
        stateLock.lock()
        if connections[connection.identifier] === connection {
            connections.removeValue(forKey: connection.identifier)
        }
        stateLock.unlock()
    }

    private func beginStopping() -> StopPlan? {
        stateLock.lock()
        if isStopped {
            stateLock.unlock()
            return nil
        }
        isStopped = true
        stopDrainGroup.enter()
        let listener = listenerDescriptor
        listenerDescriptor = -1
        let source = listenerSource
        listenerSource = nil
        let active = Array(connections.values)
        connections.removeAll()
        preparedBySourcePath.removeAll()
        stateLock.unlock()

        return StopPlan(
            listener: listener,
            source: source,
            activeConnections: active
        )
    }

    private func initiateStop(_ plan: StopPlan) {
        plan.source?.cancel()
        if plan.source == nil, plan.listener >= 0 {
            // Only possible before a dispatch source has taken ownership.
            close(plan.listener)
        } else if DispatchQueue.getSpecific(key: acceptQueueKey) == nil {
            // Drain the event and cancel handler before returning so no stale
            // listener syscall can survive view teardown.
            acceptQueue.sync {}
        }
        plan.activeConnections.forEach { $0.requestShutdown() }
        workerQueue.cancelAllOperations()
    }

    private func drainStop(_ plan: StopPlan) {
        initiateStop(plan)
        workerQueue.waitUntilAllOperationsAreFinished()
        stopDrainGroup.leave()
    }

    private static func makeSessionToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { storage in
            SecRandomCopyBytes(kSecRandomDefault, storage.count, storage.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64? {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { return nil }
        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds.isFinite,
              nanoseconds >= 1,
              nanoseconds <= Double(UInt64.max) else { return nil }
        return UInt64(nanoseconds.rounded(.up))
    }

    private static func waitUntilReady(
        descriptor: Int32,
        events: Int16,
        deadline: RenewableMonotonicDeadline
    ) -> Bool {
        while let timeout = deadline.pollTimeoutMilliseconds {
            var monitored = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&monitored, 1, timeout)
            if result < 0, errno == EINTR { continue }
            guard result > 0,
                  monitored.revents & Int16(POLLNVAL) == 0,
                  monitored.revents & (events | Int16(POLLERR) | Int16(POLLHUP)) != 0 else {
                return false
            }
            return true
        }
        return false
    }

    private static func isHTTPTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        let allowed = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        return allowed.unicodeScalars.contains(scalar)
    }

    private static func isUnsafeControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func isUnsafeHeaderScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar.value != 0x09) || scalar.value == 0x7F
    }

    private static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains(where: isUnsafeHeaderScalar)
    }
}
