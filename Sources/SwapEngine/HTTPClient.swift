import Foundation

struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

enum HTTPFailure: Error {
    case timeout
    case network(String)
}

/// Blocking HTTP, so the engine can keep cswap's synchronous shape.
protocol HTTPClient {
    func send(_ request: URLRequest, timeout: TimeInterval) throws -> HTTPResponse
}

final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest, timeout: TimeInterval) throws -> HTTPResponse {
        var req = request
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var result: Result<HTTPResponse, Error>!
        let task = session.dataTask(with: req) { data, response, error in
            if let error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                    result = .failure(HTTPFailure.timeout)
                } else {
                    result = .failure(HTTPFailure.network(error.localizedDescription))
                }
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let k = k as? String { headers[k] = "\(v)" }
                }
                result = .success(HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            } else {
                result = .failure(HTTPFailure.network("no HTTP response"))
            }
            done.signal()
        }
        task.resume()
        // URLSession's timeoutInterval is an idle timeout; bound the total too.
        if done.wait(timeout: .now() + timeout * 3) == .timedOut {
            task.cancel()
            throw HTTPFailure.timeout
        }
        return try result.get()
    }
}
