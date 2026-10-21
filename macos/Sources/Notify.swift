import Foundation

/// PushDeer notifications for things the user should know about while away from the Mac.
/// Only task-ending or hardware-risk conditions are sent (see `Controller.notify` call sites);
/// routine phase changes stay in the local history. Identical messages are not repeated
/// within half an hour, so a condition that persists does not flood the phone.
final class Notifier {
    typealias Transport = (URLRequest, @escaping (Error?) -> Void) -> Void
    static let endpoint = "https://api2.pushdeer.com/message/push"
    static let repeatInterval: TimeInterval = 1800
    var key: String
    private let transport: Transport
    private var lastSent = [String: Date]()
    private(set) var sent = [String]()

    init(key: String, transport: Transport? = nil) {
        self.key = key
        self.transport = transport ?? { request, completion in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { completion(error); return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    completion(URLError(.badServerResponse)); return
                }
                // PushDeer answers 200 with {"code":N} for its own errors (bad key, quota).
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let code = json["code"] as? Int, code != 0 {
                    completion(NSError(domain: "PushDeer", code: code,
                                       userInfo: [NSLocalizedDescriptionKey: (json["error"] as? String) ?? "code \(code)"]))
                } else { completion(nil) }
            }.resume()
        }
    }

    /// Returns false when nothing was sent (no key, or the same text within `repeatInterval`).
    @discardableResult
    func send(_ title: String, _ body: String, force: Bool = false, completion: ((Error?) -> Void)? = nil) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let text = title + "\n" + body
        if !force, let last = lastSent[text], Date().timeIntervalSince(last) < Notifier.repeatInterval { return false }
        lastSent[text] = Date()
        sent.append(text)
        var components = URLComponents(string: Notifier.endpoint)!
        components.queryItems = [URLQueryItem(name: "pushkey", value: key),
                                 URLQueryItem(name: "text", value: "Battery Tool Plus：" + title),
                                 URLQueryItem(name: "desp", value: body),
                                 URLQueryItem(name: "type", value: "text")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        transport(request) { error in DispatchQueue.main.async { completion?(error) } }
        return true
    }
}
