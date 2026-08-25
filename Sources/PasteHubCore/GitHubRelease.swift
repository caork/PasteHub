import Foundation

public struct GitHubRelease: Decodable, Sendable, Equatable {
    public let tagName: String
    public let htmlURL: String
    public let body: String?
    public let assets: [Asset]

    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }

    public init(tagName: String, htmlURL: String, body: String?, assets: [Asset]) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.body = body
        self.assets = assets
    }

    public static func decode(from data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
