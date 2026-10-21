import Foundation

public final class UpdateClient {
    public static let latestURL = URL(string: "https://raw.githubusercontent.com/Weicoz/oil-find-plus/main/updates/latest.json")!
    /// Mirrors tried in order when the primary endpoint fails. raw.githubusercontent.com is often
    /// unreachable from mainland China, so a CDN copy keeps automatic checks working there.
    public static let mirrorURLs = [
        URL(string: "https://cdn.jsdelivr.net/gh/Weicoz/oil-find-plus@main/updates/latest.json")!,
        URL(string: "https://github.com/Weicoz/oil-find-plus/raw/main/updates/latest.json")!
    ]
    public static var defaultManifestURLs: [URL] { [latestURL] + mirrorURLs }
    private let manifestURLs: [URL]
    private let version: String
    private let allowLocalhost: Bool
    /// The endpoint that answered the last successful check, for diagnostics.
    public private(set) var lastEndpoint: URL?
    public init(version: String, manifestURLs: [URL] = UpdateClient.defaultManifestURLs, allowLocalhost: Bool = false) {
        self.version = version; self.manifestURLs = manifestURLs; self.allowLocalhost = allowLocalhost
    }
    public convenience init(version: String, manifestURL: URL, allowLocalhost: Bool = false) {
        self.init(version: version, manifestURLs: [manifestURL], allowLocalhost: allowLocalhost)
    }
    static func configuration(version: String, request: TimeInterval, resource: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": "OilFindPlus/" + version, "Accept-Language": ""]
        return config
    }
    public func check() async throws -> UpdateManifest {
        let result = try await UpdateClient.firstManifest(from: manifestURLs) { url in
            try await self.fetchManifest(from: url)
        }
        lastEndpoint = result.endpoint
        return result.manifest
    }
    /// Runs the per-endpoint fetch against every endpoint in order and returns the first success
    /// with the endpoint that answered. Kept separate so the fallback order is testable offline.
    static func firstManifest(from urls: [URL], fetch: (URL) async throws -> UpdateManifest) async throws -> (endpoint: URL, manifest: UpdateManifest) {
        var failure = UpdateFailure.network
        for url in urls {
            do { return (url, try await fetch(url)) }
            catch let error as UpdateFailure { failure = error }
            catch { failure = .network }
        }
        throw failure
    }
    private func fetchManifest(from manifestURL: URL) async throws -> UpdateManifest {
        guard UpdateManifest.validURL(manifestURL, allowLocalhost: allowLocalhost) else { throw UpdateFailure.other }
        let session = URLSession(configuration: UpdateClient.configuration(version: version, request: 12, resource: 20), delegate: UpdateFollowRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: manifestURL) }
        catch { throw UpdateFailure.network }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.network }
        let manifest = try UpdateManifest.parse(data, allowLocalhost: allowLocalhost)
        let allowedHosts: Set<String> = [
            manifestURL.host ?? "",
            "cdn.jsdelivr.net",
            "github.com",
            "api.github.com",
            "raw.githubusercontent.com",
            "objects.githubusercontent.com",
            "github-releases.githubusercontent.com"
        ]
        if let host = manifest.url.host {
            guard allowedHosts.contains(host) || host.hasSuffix(".githubusercontent.com") || host == manifestURL.host else {
                throw UpdateFailure.other
            }
        } else {
            throw UpdateFailure.other
        }
        return manifest
    }
    // The returned directory belongs to the caller and must be removed after use.
    public func download(_ manifest: UpdateManifest, progress: @escaping (Double) -> Void) async throws -> URL {
        guard UpdateManifest.validURL(manifest.url, allowLocalhost: allowLocalhost) else { throw UpdateFailure.other }
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = UpdateDownload(size: manifest.size, progress: progress) { continuation.resume(with: $0) }
            let session = URLSession(configuration: UpdateClient.configuration(version: self.version, request: 30, resource: 600), delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: manifest.url).resume()
        }
    }
}

private class UpdateFollowRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, url.scheme == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

private final class UpdateDownload: UpdateFollowRedirect, URLSessionDownloadDelegate {
    private let size: Int64
    private let progress: (Double) -> Void
    private var completion: ((Result<URL, Error>) -> Void)?
    private var failure: UpdateFailure?
    init(size: Int64, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.size = size; self.progress = progress; self.completion = completion
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > size { failure = .integrity; downloadTask.cancel() }
        else { progress(min(1, Double(totalBytesWritten) / Double(size))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { finish(session, .failure(UpdateFailure.network)); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-download-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let archive = directory.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: location, to: archive)
            finish(session, .success(archive))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            finish(session, .failure(UpdateFailure.other))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(session, .failure(failure ?? (error is URLError ? UpdateFailure.network : UpdateFailure.other))) }
    }
    private func finish(_ session: URLSession, _ result: Result<URL, Error>) {
        let callback = completion; completion = nil
        callback?(result); session.finishTasksAndInvalidate()
    }
}
