import Darwin
import Foundation

/// One policy boundary for external Web wallpaper destinations. The app's
/// WKContentRuleList uses the same patterns for subresources and WebSockets,
/// while import/configuration probes use the host classifier before claiming
/// that an opted-in wallpaper can load successfully.
public enum WebWallpaperNetworkPolicy {
    public static let blockedHTTPOriginPatterns: [String] = {
        var patterns = [
        // Ambiguous numeric IPv4 spellings are interpreted differently across
        // URL/network stacks. Block them instead of trying to prove they are
        // public from one parser's normalization.
        #"^https?://([^/@]*@)?[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?0[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?[0-9]+\.0[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?[0-9]+\.[0-9]+\.0[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?[0-9]+\.[0-9]+\.[0-9]+\.0[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?([^/]+\.)?localhost\.?(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?[^/]+\.local\.?(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?0\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?127\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?10\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?100\.6[4-9]\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?100\.[7-9][0-9]\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?100\.1[01][0-9]\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?100\.12[0-7]\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?169\.254\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?172\.1[6-9]\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?172\.2[0-9]\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?172\.3[01]\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?192\.168\.[0-9]+\.[0-9]+(:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?\[::\](:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?\[::1\](:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?\[0+:0+:0+:0+:0+:0+:0+:[01]\](:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?\[fc[0-9a-f:.]*\](:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?\[fd[0-9a-f:.]*\](:[0-9]+)?/"#,
        #"^https?://([^/@]*@)?\[fe[89ab][0-9a-f:.]*\](:[0-9]+)?/"#,
        // A scoped IPv6 literal is inherently interface-local. URL strings
        // retain the percent-encoded zone separator (`%25`) when WebKit's
        // content rules see them, so block any bracketed host with a zone.
        #"^https?://([^/@]*@)?\[[^/]*%[^/]*\](:[0-9]+)?/"#
        ]

        // WebKit content-rule regular expressions do not support alternation.
        // Enumerate every 1...4-component IPv4 spelling containing at least
        // one hexadecimal component. This blocks numeric hosts such as
        // `0x7f000001` without treating ordinary DNS names such as
        // `0xdead.beef` as numeric addresses.
        let decimalComponent = #"[0-9]+"#
        let hexadecimalComponent = #"0x[0-9a-f]+"#
        for componentCount in 1...4 {
            for hexadecimalMask in 1..<(1 << componentCount) {
                let components = (0..<componentCount).map { index in
                    hexadecimalMask & (1 << index) == 0
                        ? decimalComponent
                        : hexadecimalComponent
                }
                patterns.append(
                    #"^https?://([^/@]*@)?"#
                        + components.joined(separator: #"\."#)
                        + #"(:[0-9]+)?/"#
                )
            }
        }

        func zeroRunSpellings(groupCount: Int) -> [String] {
            var spellings = [
                Array(repeating: "0+", count: groupCount).joined(separator: ":") + ":"
            ]
            // The compressed run can have explicit zero groups on either
            // side. Keep the trailing separator ready for the next group.
            for leftCount in 0..<groupCount {
                for rightCount in 0..<(groupCount - leftCount) {
                    let left = Array(repeating: "0+", count: leftCount).joined(separator: ":")
                    let right = Array(repeating: "0+", count: rightCount).joined(separator: ":")
                    var spelling = left.isEmpty ? "::" : left + "::"
                    if !right.isEmpty { spelling += right + ":" }
                    spellings.append(spelling)
                }
            }
            return Array(Set(spellings)).sorted()
        }

        // IPv4-mapped IPv6 addresses have five zero groups followed by
        // `ffff`. Enumerating every legal compression placement keeps the
        // pattern precise: a public address merely containing an `ffff`
        // segment (for example `2001:db8:ffff::1`) remains available.
        for prefix in zeroRunSpellings(groupCount: 5) {
            let originPrefix = #"^https?://([^/@]*@)?\["# + prefix + "ffff:"
            let hexadecimalGroup = #"[0-9a-f][0-9a-f]?[0-9a-f]?[0-9a-f]?"#
            patterns.append(
                originPrefix
                    + hexadecimalGroup + ":" + hexadecimalGroup
                    + #"\](:[0-9]+)?/"#
            )
            patterns.append(
                originPrefix
                    + #"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\](:[0-9]+)?/"#
            )
        }

        // Apply the same normalization coverage to loopback. WebKit normally
        // canonicalizes this to `::1`, but matching every legal spelling keeps
        // the runtime denylist aligned with the host classifier.
        for prefix in zeroRunSpellings(groupCount: 7) {
            patterns.append(
                #"^https?://([^/@]*@)?\["#
                    + prefix
                    + #"1\](:[0-9]+)?/"#
            )
        }
        // URL preserves the legal dotted-tail spelling of IPv6 unspecified
        // and loopback literals (for example `[::0.0.0.1]`) even though
        // inet_pton canonicalizes the same host to `::1`. Match every legal
        // compression placement so subresource/WebSocket rules agree with the
        // host classifier.
        for prefix in zeroRunSpellings(groupCount: 6) {
            patterns.append(
                #"^https?://([^/@]*@)?\["#
                    + prefix
                    + #"0\.0\.0\.[01]\](:[0-9]+)?/"#
            )
        }
        return patterns
    }()

    public static func isBlockedExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme) else {
            return false
        }
        return isBlockedExternalHost(url.host)
    }

    public static func isBlockedExternalHost(_ rawHost: String?) -> Bool {
        guard let rawHost else { return true }
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !host.contains("%") else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }

        let numericParts = host.split(separator: ".", omittingEmptySubsequences: false)
        let decimalComponent: (Substring) -> Bool = { component in
            !component.isEmpty && component.allSatisfy { ("0"..."9").contains($0) }
        }
        let hexadecimalComponent: (Substring) -> Bool = { component in
            component.count > 2
                && component.hasPrefix("0x")
                && component.dropFirst(2).allSatisfy {
                    ("0"..."9").contains($0) || ("a"..."f").contains($0)
                }
        }
        if (1...4).contains(numericParts.count),
           numericParts.allSatisfy({ decimalComponent($0) || hexadecimalComponent($0) }) {
            let usesLegacySyntax = numericParts.count != 4
                || numericParts.contains(where: hexadecimalComponent)
                || numericParts.contains { component in
                    decimalComponent(component) && component.count > 1 && component.first == "0"
                }
            if usesLegacySyntax { return true }
        }
        var ipv4 = in_addr()
        if Darwin.inet_aton(host, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            let first = UInt8((address >> 24) & 0xff)
            let second = UInt8((address >> 16) & 0xff)
            return first == 0
                || first == 10
                || first == 127
                || (first == 100 && (64...127).contains(second))
                || (first == 169 && second == 254)
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168)
        }

        var ipv6 = in6_addr()
        guard Darwin.inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { rawBytes in
            let bytes = Array(rawBytes)
            let isUnspecified = bytes.allSatisfy { $0 == 0 }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = bytes.first.map { $0 & 0xfe == 0xfc } ?? false
            let isLinkLocal = bytes.count >= 2 && bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            let isIPv4Mapped = bytes.count == 16
                && bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
            return isUnspecified || isLoopback || isUniqueLocal || isLinkLocal || isIPv4Mapped
        }
    }
}
