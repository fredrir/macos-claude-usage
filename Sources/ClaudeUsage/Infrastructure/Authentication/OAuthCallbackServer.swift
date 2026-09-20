import Darwin
import Foundation

public enum OAuthServerError: LocalizedError, Sendable {
    case portUnavailable(UInt16)
    case socketCreationFailed(Int32)
    case socketBindFailed(Int32)
    case socketListenFailed(Int32)
    case stateMismatch
    case errorReturned(String)
    case missingCode
    case timedOut
    case cancelled
    case malformedAuthorizeURL
    case browserLaunchFailed

    public var errorDescription: String? {
        switch self {
        case .portUnavailable(let port):
            return "Port \(port) is already in use by another application."
        case .socketCreationFailed(let code):
            return "Could not create local socket (error code \(code))."
        case .socketBindFailed(let code):
            return "Could not bind local socket (error code \(code))."
        case .socketListenFailed(let code):
            return "Could not listen on local socket (error code \(code))."
        case .stateMismatch:
            return "Security verification failed: OAuth state did not match. Please try signing in again."
        case .errorReturned(let error):
            return "Sign-in failed with error: \(error)"
        case .missingCode:
            return "The authorization response did not contain an authorization code."
        case .timedOut:
            return "Sign-in timed out. Please try again."
        case .cancelled:
            return "Sign-in was cancelled."
        case .malformedAuthorizeURL:
            return "The sign-in URL could not be built — check the configured OAuth settings."
        case .browserLaunchFailed:
            return "The sign-in page could not be opened in your browser."
        }
    }
}

private final class ServerState: @unchecked Sendable {
    var listeningSocket: Int32 = -1
    var boundPort: UInt16 = 0
    var isRunning = false

    deinit {
        if listeningSocket >= 0 {
            close(listeningSocket)
        }
    }
}

public actor OAuthCallbackServer {
    private let state = ServerState()

    public init() {}

    public func start(preferredPort: UInt16 = 0) throws -> UInt16 {
        stopListening()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthServerError.socketCreationFailed(errno)
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult != 0 {
            let err = errno
            close(fd)
            if err == EADDRINUSE {
                throw OAuthServerError.portUnavailable(preferredPort)
            }
            throw OAuthServerError.socketBindFailed(err)
        }

        if listen(fd, 5) != 0 {
            let err = errno
            close(fd)
            throw OAuthServerError.socketListenFailed(err)
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actualAddr = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }

        state.listeningSocket = fd
        state.boundPort = UInt16(bigEndian: actualAddr.sin_port)
        state.isRunning = true
        return state.boundPort
    }

    public func waitForAuthorizationCode(
        expectedPath: String,
        expectedState: String?,
        providerName: String,
        timeout: TimeInterval = 300
    ) async throws -> String {
        guard state.isRunning, state.listeningSocket >= 0 else {
            throw OAuthServerError.socketListenFailed(EBADF)
        }

        let deadline = Date().addingTimeInterval(timeout)

        while state.isRunning {
            if Task.isCancelled {
                stopListening()
                throw OAuthServerError.cancelled
            }

            if Date() > deadline {
                stopListening()
                throw OAuthServerError.timedOut
            }

            var pfd = pollfd(fd: state.listeningSocket, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pfd, 1, 250)

            if pollResult < 0 {
                if errno == EINTR { continue }
                stopListening()
                throw OAuthServerError.socketListenFailed(errno)
            }

            if pollResult == 0 {
                await Task.yield()
                continue
            }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(state.listeningSocket, $0, &clientLen)
                }
            }

            guard clientFd >= 0 else {
                if errno == EINTR { continue }
                continue
            }

            if let result = handleClientConnection(
                clientFd: clientFd,
                expectedPath: expectedPath,
                expectedState: expectedState,
                providerName: providerName
            ) {
                stopListening()
                return try result.get()
            }
        }

        throw OAuthServerError.cancelled
    }

    public func stopListening() {
        state.isRunning = false
        if state.listeningSocket >= 0 {
            close(state.listeningSocket)
            state.listeningSocket = -1
        }
    }

    private func handleClientConnection(
        clientFd: Int32,
        expectedPath: String,
        expectedState: String?,
        providerName: String
    ) -> Result<String, OAuthServerError>? {
        defer { close(clientFd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientFd, &buffer, buffer.count)
        guard bytesRead > 0 else { return nil }

        let requestString = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        guard let firstLine = requestString.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendResponse(to: clientFd, status: "400 Bad Request", body: "Bad Request")
            return nil
        }

        let requestPath = parts[1]
        guard let components = URLComponents(string: "http://127.0.0.1" + requestPath) else {
            sendResponse(to: clientFd, status: "400 Bad Request", body: "Invalid URL")
            return nil
        }

        if components.path == "/favicon.ico" {
            sendResponse(to: clientFd, status: "404 Not Found", body: "")
            return nil
        }

        guard components.path == expectedPath else {
            sendResponse(to: clientFd, status: "404 Not Found", body: "Not Found")
            return nil
        }

        let queryItems = components.queryItems ?? []
        let code = queryItems.first(where: { $0.name == "code" })?.value
        let state = queryItems.first(where: { $0.name == "state" })?.value
        let error = queryItems.first(where: { $0.name == "error" })?.value
        let errorDesc = queryItems.first(where: { $0.name == "error_description" })?.value

        if let error {
            let message = errorDesc ?? error
            sendHTML(
                to: clientFd,
                title: "Sign-in Failed",
                headline: "Sign-in Failed",
                message: "Authentication was rejected: \(message)",
                isSuccess: false
            )
            return .failure(.errorReturned(message))
        }

        if let expectedState, state != expectedState {
            sendHTML(
                to: clientFd,
                title: "Security Verification Failed",
                headline: "Verification Failed",
                message: "OAuth state mismatch. Please return to Claude Usage and try again.",
                isSuccess: false
            )
            return .failure(.stateMismatch)
        }

        guard let code, !code.isEmpty else {
            sendHTML(
                to: clientFd,
                title: "Sign-in Failed",
                headline: "Missing Authorization Code",
                message: "No authorization code was returned by the identity provider.",
                isSuccess: false
            )
            return .failure(.missingCode)
        }

        sendHTML(
            to: clientFd,
            title: "Signed In",
            headline: "✓ Signed In to \(providerName)",
            message: "Authentication is complete. You can close this window and return to Claude Usage.",
            isSuccess: true
        )

        return .success(code)
    }

    private func sendHTML(
        to fd: Int32,
        title: String,
        headline: String,
        message: String,
        isSuccess: Bool
    ) {
        let accentColor = isSuccess ? "#34c759" : "#ff3b30"
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
          <style>
            * { box-sizing: border-box; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              margin: 0;
              background-color: #f5f5f7;
              color: #1d1d1f;
              padding: 20px;
            }
            @media (prefers-color-scheme: dark) {
              body { background-color: #1c1c1e; color: #f5f5f7; }
              .card { background-color: #2c2c2e !important; box-shadow: 0 4px 24px rgba(0,0,0,0.4) !important; }
              .message { color: #a1a1a6 !important; }
            }
            .card {
              background: #ffffff;
              padding: 40px;
              border-radius: 18px;
              box-shadow: 0 4px 24px rgba(0, 0, 0, 0.08);
              text-align: center;
              max-width: 420px;
              width: 100%;
            }
            .headline {
              font-size: 21px;
              font-weight: 600;
              margin: 0 0 12px 0;
              color: \(accentColor);
            }
            .message {
              font-size: 14px;
              color: #6e6e73;
              line-height: 1.5;
              margin: 0;
            }
          </style>
        </head>
        <body>
          <div class="card">
            <h1 class="headline">\(headline)</h1>
            <p class="message">\(message)</p>
          </div>
        </body>
        </html>
        """
        sendResponse(to: fd, status: "200 OK", body: html, contentType: "text/html; charset=utf-8")
    }

    private func sendResponse(
        to fd: Int32,
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8"
    ) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(bodyData)
        responseData.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                _ = write(fd, baseAddress, ptr.count)
            }
        }
    }
}
