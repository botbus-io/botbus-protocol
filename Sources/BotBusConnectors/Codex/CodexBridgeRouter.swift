import Foundation
import BotBusConnectorKit

/// One app-server connection belongs to the desktop. The Agent is an optional second client.
/// All mutations are serialized by the host actor; this value holds only protocol bookkeeping.
struct CodexBridgeRouter {
    enum Delivery: Equatable {
        case upstream(JSONValue)
        case desktop(JSONValue)
        case agent(String, JSONValue)

        var message: JSONValue {
            switch self {
            case .upstream(let value), .desktop(let value), .agent(_, let value): return value
            }
        }
    }

    enum Failure: Error, Equatable {
        case notReady, staleSession, forbiddenMethod, unknownApproval, tooManyRequests
    }

    private struct Origin {
        let session: String?
        let originalID: JSONValue
        let method: String
    }

    private struct ServerRequest {
        let method: String
        let threadId: String?
        let turnId: String?
        let message: JSONValue

        var canPhoneAnswer: Bool {
            Self.phoneApprovalMethods.contains(method)
        }

        static let phoneApprovalMethods: Set<String> = [
            "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
            "item/permissions/requestApproval", "item/tool/requestUserInput",
        ]
    }

    private static let agentMethods: Set<String> = [
        "thread/start", "thread/resume", "thread/read", "thread/loaded/list",
        "turn/start", "turn/steer", "turn/interrupt",
    ]
    private static let requestLimit = 1024
    private static let serverRequestLimit = 128

    private var nextID: Int64 = 1
    private var outbound: [JSONValue: Origin] = [:]
    private var serverRequests: [JSONValue: ServerRequest] = [:]
    private var serverRequestOrder: [JSONValue] = []
    private var activeTurns: [String: JSONValue] = [:]
    private(set) var initializeResult: JSONValue?
    private(set) var agentSession: String?

    // Current desktop clients start sending requests after the initialize response
    // without sending an `initialized` notification. If one is sent, it is forwarded
    // unchanged, but it must not gate attachment to an already initialized upstream.
    var ready: Bool { initializeResult != nil }

    mutating func attach(_ session: String) -> [JSONValue] {
        agentSession = session
        outbound = outbound.filter { $0.value.session == nil }
        let running = activeTurns.keys.sorted().compactMap { activeTurns[$0] }
        let approvals: [JSONValue] = serverRequestOrder.compactMap { key -> JSONValue? in
            guard let request = serverRequests[key], request.canPhoneAnswer else { return nil }
            return request.message
        }
        return running + approvals
    }

    mutating func detach() {
        agentSession = nil
        outbound = outbound.filter { $0.value.session == nil }
    }

    /// Desktop requests keep their full params but receive private upstream IDs.
    mutating func desktop(_ message: JSONValue) -> [Delivery] {
        if let method = message["method"]?.stringValue {
            if let originalID = message["id"] {
                guard outbound.count < Self.requestLimit else {
                    return [.desktop(["id": originalID, "error": [
                        "code": -32000, "message": "Codex bridge request limit exceeded",
                    ]])]
                }
                let upstreamID = nextRequestID()
                outbound[upstreamID] = Origin(session: nil, originalID: originalID, method: method)
                return [.upstream(replacingID(message, with: upstreamID))]
            }
            return [.upstream(message)]
        }
        guard let id = message["id"], let request = serverRequests.removeValue(forKey: id) else {
            return [] // late duplicate, including one already answered from phone
        }
        serverRequestOrder.removeAll { $0 == id }
        var deliveries: [Delivery] = [.upstream(message)]
        if request.canPhoneAnswer, let agentSession {
            deliveries.append(.agent(agentSession, resolved(id: id, request: request)))
        }
        return deliveries
    }

    mutating func agent(_ message: JSONValue, session: String) throws -> [Delivery] {
        guard ready else { throw Failure.notReady }
        guard agentSession == session else { throw Failure.staleSession }
        if let method = message["method"]?.stringValue {
            guard Self.agentMethods.contains(method) else { throw Failure.forbiddenMethod }
            guard let originalID = message["id"] else { throw Failure.forbiddenMethod }
            guard outbound.count < Self.requestLimit else { throw Failure.tooManyRequests }
            let upstreamID = nextRequestID()
            outbound[upstreamID] = Origin(session: session, originalID: originalID, method: method)
            return [.upstream(replacingID(message, with: upstreamID))]
        }
        guard let id = message["id"], let request = serverRequests[id], request.canPhoneAnswer else {
            throw Failure.unknownApproval
        }
        serverRequests.removeValue(forKey: id)
        serverRequestOrder.removeAll { $0 == id }
        return [.upstream(message), .desktop(resolved(id: id, request: request))]
    }

    mutating func upstream(_ message: JSONValue) -> [Delivery] {
        if let id = message["id"], message["method"] == nil {
            guard let origin = outbound.removeValue(forKey: id) else { return [] }
            let restored = replacingID(message, with: origin.originalID)
            if origin.method == "initialize", origin.session == nil, let result = message["result"] {
                initializeResult = result
            }
            if let session = origin.session {
                return session == agentSession ? [.agent(session, restored)] : []
            }
            return [.desktop(restored)]
        }
        if let method = message["method"]?.stringValue {
            if let id = message["id"] {
                let params = message["params"]
                let request = ServerRequest(method: method,
                                            threadId: params?["threadId"]?.stringValue,
                                            turnId: params?["turnId"]?.stringValue,
                                            message: message)
                serverRequests[id] = request
                serverRequestOrder.append(id)
                while serverRequestOrder.count > Self.serverRequestLimit {
                    serverRequests.removeValue(forKey: serverRequestOrder.removeFirst())
                }
                var deliveries: [Delivery] = [.desktop(message)]
                if request.canPhoneAnswer, let agentSession {
                    deliveries.append(.agent(agentSession, message))
                }
                return deliveries
            }
            if method == "turn/started", let threadId = message["params"]?["threadId"]?.stringValue {
                activeTurns[threadId] = message
            } else if method == "turn/completed" {
                let params = message["params"]
                let threadId = params?["threadId"]?.stringValue
                if let threadId { activeTurns.removeValue(forKey: threadId) }
                let turnId = params?["turn"]?["id"]?.stringValue
                for id in serverRequestOrder where serverRequests[id]?.threadId == threadId &&
                    (turnId == nil || serverRequests[id]?.turnId == nil || serverRequests[id]?.turnId == turnId) {
                    serverRequests.removeValue(forKey: id)
                }
                serverRequestOrder.removeAll { serverRequests[$0] == nil }
            } else if method == "serverRequest/resolved", let id = message["params"]?["requestId"] {
                serverRequests.removeValue(forKey: id)
                serverRequestOrder.removeAll { $0 == id }
            }
            var deliveries: [Delivery] = [.desktop(message)]
            if let agentSession { deliveries.append(.agent(agentSession, message)) }
            return deliveries
        }
        return [.desktop(message)]
    }

    private mutating func nextRequestID() -> JSONValue {
        defer { nextID += 1 }
        return .string("botbus-\(nextID)")
    }

    private func replacingID(_ message: JSONValue, with id: JSONValue) -> JSONValue {
        var object = message.objectValue ?? [:]
        object["id"] = id
        return .object(object)
    }

    private func resolved(id: JSONValue, request: ServerRequest) -> JSONValue {
        ["method": "serverRequest/resolved", "params": [
            "requestId": id,
            "threadId": .string(request.threadId ?? ""),
        ]]
    }
}
