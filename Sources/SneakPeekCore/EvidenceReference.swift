import Foundation

/// Agent-authored local references are revealed, never launched through a file
/// association. This also covers apps, scripts, aliases and symbolic links.
public enum EvidenceReference: Equatable, Sendable {
    case reveal(URL)
    case website(URL)
    case unsupported

    public init(_ reference: String) {
        if reference.hasPrefix("/") {
            self = .reveal(URL(fileURLWithPath: reference)); return
        }
        guard let url = URL(string: reference) else { self = .unsupported; return }
        if url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
           url.user == nil, url.password == nil {
            self = .website(url)
        } else if url.isFileURL, [nil, "", "localhost"].contains(url.host?.lowercased()),
                  url.path.hasPrefix("/"), url.query == nil, url.fragment == nil {
            self = .reveal(url)
        } else { self = .unsupported }
    }

    public var buttonLabel: String {
        switch self {
        case .reveal: "Show in Finder"
        case .website: "Open website"
        case .unsupported: "Inspect at source"
        }
    }
}
