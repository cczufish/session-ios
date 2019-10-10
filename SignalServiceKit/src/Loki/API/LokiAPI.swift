import PromiseKit

@objc(LKAPI)
public final class LokiAPI : NSObject {
    private static var lastDeviceLinkUpdate: [String:Date] = [:] // Hex encoded public key to date
    @objc static var userIDCache: [String:Set<String>] = [:] // Thread ID to set of user hex encoded public keys
    
    // MARK: Convenience
    internal static let storage = OWSPrimaryStorage.shared()
    internal static let userHexEncodedPublicKey = OWSIdentityManager.shared().identityKeyPair()!.hexEncodedPublicKey
    
    // MARK: Settings
    private static let version = "v1"
    private static let maxRetryCount: UInt = 8
    private static let defaultTimeout: TimeInterval = 20
    private static let longPollingTimeout: TimeInterval = 40
    private static let deviceLinkUpdateInterval: TimeInterval = 8 * 60
    private static let receivedMessageHashValuesKey = "receivedMessageHashValuesKey"
    private static let receivedMessageHashValuesCollection = "receivedMessageHashValuesCollection"
    private static var userIDScanLimit: UInt = 4096
    internal static var powDifficulty: UInt = 4
    public static let defaultMessageTTL: UInt64 = 24 * 60 * 60 * 1000
    
    // MARK: Types
    public typealias RawResponse = Any
    
    public enum Error : LocalizedError {
        /// Only applicable to snode targets as proof of work isn't required for P2P messaging.
        case proofOfWorkCalculationFailed
        case messageConversionFailed
        
        public var errorDescription: String? {
            switch self {
            case .proofOfWorkCalculationFailed: return NSLocalizedString("Failed to calculate proof of work.", comment: "")
            case .messageConversionFailed: return "Failed to convert Signal message to Loki message."
            }
        }
    }
    
    @objc(LKDestination)
    public final class Destination : NSObject {
        @objc public let hexEncodedPublicKey: String
        @objc(kind)
        public let objc_kind: String
        
        public var kind: Kind {
            return Kind(rawValue: objc_kind)!
        }
        
        public enum Kind : String { case master, slave }
        
        public init(hexEncodedPublicKey: String, kind: Kind) {
            self.hexEncodedPublicKey = hexEncodedPublicKey
            self.objc_kind = kind.rawValue
        }
        
        @objc public init(hexEncodedPublicKey: String, kind: String) {
            self.hexEncodedPublicKey = hexEncodedPublicKey
            self.objc_kind = kind
        }
        
        override public func isEqual(_ other: Any?) -> Bool {
            guard let other = other as? Destination else { return false }
            return hexEncodedPublicKey == other.hexEncodedPublicKey && kind == other.kind
        }
        
        override public var hash: Int { // Override NSObject.hash and not Hashable.hashValue or Hashable.hash(into:)
            return hexEncodedPublicKey.hashValue ^ kind.hashValue
        }

        override public var description: String { return "\(kind.rawValue)(\(hexEncodedPublicKey))" }
    }
    
    public typealias MessageListPromise = Promise<[SSKProtoEnvelope]>
    public typealias RawResponsePromise = Promise<RawResponse>
    
    // MARK: Lifecycle
    override private init() { }
    
    // MARK: Internal API
    internal static func invoke(_ method: LokiAPITarget.Method, on target: LokiAPITarget, associatedWith hexEncodedPublicKey: String,
        parameters: [String:Any], headers: [String:String]? = nil, timeout: TimeInterval? = nil) -> RawResponsePromise {
        let url = URL(string: "\(target.address):\(target.port)/storage_rpc/\(version)")!
        let request = TSRequest(url: url, method: "POST", parameters: [ "method" : method.rawValue, "params" : parameters ])
        if let headers = headers { request.allHTTPHeaderFields = headers }
        request.timeoutInterval = timeout ?? defaultTimeout
        let headers = request.allHTTPHeaderFields ?? [:]
        let headersDescription = headers.isEmpty ? "no custom headers specified" : headers.prettifiedDescription
        print("[Loki] Invoking \(method.rawValue) on \(target) with \(parameters.prettifiedDescription) (\(headersDescription)).")
        return TSNetworkManager.shared().makePromise(request: request).map { $0.responseObject }
            .handlingSwarmSpecificErrorsIfNeeded(for: target, associatedWith: hexEncodedPublicKey).recoveringNetworkErrorsIfNeeded()
    }
    
    internal static func getRawMessages(from target: LokiAPITarget, usingLongPolling useLongPolling: Bool) -> RawResponsePromise {
        let lastHashValue = getLastMessageHashValue(for: target) ?? ""
        let parameters = [ "pubKey" : userHexEncodedPublicKey, "lastHash" : lastHashValue ]
        let headers: [String:String]? = useLongPolling ? [ "X-Loki-Long-Poll" : "true" ] : nil
        let timeout: TimeInterval? = useLongPolling ? longPollingTimeout : nil
        return invoke(.getMessages, on: target, associatedWith: userHexEncodedPublicKey, parameters: parameters, headers: headers, timeout: timeout)
    }
    
    // MARK: Public API
    public static func getMessages() -> Promise<Set<MessageListPromise>> {
        return getTargetSnodes(for: userHexEncodedPublicKey).mapValues { targetSnode in
            return getRawMessages(from: targetSnode, usingLongPolling: false).map { parseRawMessagesResponse($0, from: targetSnode) }
        }.map { Set($0) }.retryingIfNeeded(maxRetryCount: maxRetryCount)
    }
    
    public static func getDestinations(for hexEncodedPublicKey: String) -> Promise<[Destination]> {
        let (promise, seal) = Promise<[Destination]>.pending()
        func getDestinations() {
            storage.dbReadConnection.read { transaction in
                var destinations: [Destination] = []
                let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
                let masterDestination = Destination(hexEncodedPublicKey: masterHexEncodedPublicKey, kind: .master)
                destinations.append(masterDestination)
                let deviceLinks = storage.getDeviceLinks(for: masterHexEncodedPublicKey, in: transaction)
                let slaveDestinations = deviceLinks.map { Destination(hexEncodedPublicKey: $0.slave.hexEncodedPublicKey, kind: .slave) }
                destinations.append(contentsOf: slaveDestinations)
                destinations = destinations.filter { $0.hexEncodedPublicKey != userHexEncodedPublicKey }
                seal.fulfill(destinations)
            }
        }
        let timeSinceLastUpdate: TimeInterval
        if let lastDeviceLinkUpdate = lastDeviceLinkUpdate[hexEncodedPublicKey] {
            timeSinceLastUpdate = Date().timeIntervalSince(lastDeviceLinkUpdate)
        } else {
            timeSinceLastUpdate = .infinity
        }
        if timeSinceLastUpdate > deviceLinkUpdateInterval {
            storage.dbReadConnection.read { transaction in
                let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
                LokiStorageAPI.getDeviceLinks(associatedWith: masterHexEncodedPublicKey).done { _ in
                    getDestinations()
                    lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
                }.catch { error in
                    if case LokiDotNetAPI.Error.parsingFailed = error {
                        // Don't immediately re-fetch in case of failure due to a parsing error
                        lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
                        getDestinations()
                    } else {
                        seal.reject(error)
                    }
                }
            }
        } else {
            getDestinations()
        }
        return promise
    }
    
    public static func sendSignalMessage(_ signalMessage: SignalMessage, onP2PSuccess: @escaping () -> Void) -> Promise<Set<RawResponsePromise>> {
        guard let lokiMessage = LokiMessage.from(signalMessage: signalMessage) else { return Promise(error: Error.messageConversionFailed) }
        let destination = lokiMessage.destination
        func sendLokiMessage(_ lokiMessage: LokiMessage, to target: LokiAPITarget) -> RawResponsePromise {
            let parameters = lokiMessage.toJSON()
            return invoke(.sendMessage, on: target, associatedWith: destination, parameters: parameters)
        }
        func sendLokiMessageUsingSwarmAPI() -> Promise<Set<RawResponsePromise>> {
            return lokiMessage.calculatePoW().then { lokiMessageWithPoW in
                return getTargetSnodes(for: destination).map { swarm in
                    return Set(swarm.map { target in
                        sendLokiMessage(lokiMessageWithPoW, to: target).map { rawResponse in
                            if let json = rawResponse as? JSON, let powDifficulty = json["difficulty"] as? Int {
                                guard powDifficulty != LokiAPI.powDifficulty else { return rawResponse }
                                print("[Loki] Setting proof of work difficulty to \(powDifficulty).")
                                LokiAPI.powDifficulty = UInt(powDifficulty)
                            } else {
                                print("[Loki] Failed to update proof of work difficulty from: \(rawResponse).")
                            }
                            return rawResponse
                        }
                    })
                }.retryingIfNeeded(maxRetryCount: maxRetryCount)
            }
        }
        if let peer = LokiP2PAPI.getInfo(for: destination), (lokiMessage.isPing || peer.isOnline) {
            let target = LokiAPITarget(address: peer.address, port: peer.port)
            return Promise.value([ target ]).mapValues { sendLokiMessage(lokiMessage, to: $0) }.map { Set($0) }.retryingIfNeeded(maxRetryCount: maxRetryCount).get { _ in
                LokiP2PAPI.markOnline(destination)
                onP2PSuccess()
            }.recover { error -> Promise<Set<RawResponsePromise>> in
                LokiP2PAPI.markOffline(destination)
                if lokiMessage.isPing {
                    print("[Loki] Failed to ping \(destination); marking contact as offline.")
                    if let error = error as? NSError {
                        error.isRetryable = false
                        throw error
                    } else {
                        throw error
                    }
                }
                return sendLokiMessageUsingSwarmAPI()
            }
        } else {
            return sendLokiMessageUsingSwarmAPI()
        }
    }
    
    // MARK: Public API (Obj-C)
    @objc(getDestinationsFor:)
    public static func objc_getDestinations(for hexEncodedPublicKey: String) -> AnyPromise {
        let promise = getDestinations(for: hexEncodedPublicKey)
        return AnyPromise.from(promise)
    }
    
    @objc(sendSignalMessage:onP2PSuccess:)
    public static func objc_sendSignalMessage(_ signalMessage: SignalMessage, onP2PSuccess: @escaping () -> Void) -> AnyPromise {
        let promise = sendSignalMessage(signalMessage, onP2PSuccess: onP2PSuccess).mapValues { AnyPromise.from($0) }.map { Set($0) }
        return AnyPromise.from(promise)
    }
    
    // MARK: Parsing
    
    // The parsing utilities below use a best attempt approach to parsing; they warn for parsing failures but don't throw exceptions.
    
    internal static func parseRawMessagesResponse(_ rawResponse: Any, from target: LokiAPITarget) -> [SSKProtoEnvelope] {
        guard let json = rawResponse as? JSON, let rawMessages = json["messages"] as? [JSON] else { return [] }
        updateLastMessageHashValueIfPossible(for: target, from: rawMessages)
        let newRawMessages = removeDuplicates(from: rawMessages)
        let newMessages = parseProtoEnvelopes(from: newRawMessages)
        let newMessageCount = newMessages.count
        if newMessageCount == 1 {
            print("[Loki] Retrieved 1 new message.")
        } else if (newMessageCount != 0) {
            print("[Loki] Retrieved \(newMessageCount) new messages.")
        }
        return newMessages
    }
    
    private static func updateLastMessageHashValueIfPossible(for target: LokiAPITarget, from rawMessages: [JSON]) {
        if let lastMessage = rawMessages.last, let hashValue = lastMessage["hash"] as? String, let expirationDate = lastMessage["expiration"] as? Int {
            setLastMessageHashValue(for: target, hashValue: hashValue, expirationDate: UInt64(expirationDate))
        } else if (!rawMessages.isEmpty) {
            print("[Loki] Failed to update last message hash value from: \(rawMessages).")
        }
    }
    
    private static func removeDuplicates(from rawMessages: [JSON]) -> [JSON] {
        var receivedMessageHashValues = getReceivedMessageHashValues() ?? []
        return rawMessages.filter { rawMessage in
            guard let hashValue = rawMessage["hash"] as? String else {
                print("[Loki] Missing hash value for message: \(rawMessage).")
                return false
            }
            let isDuplicate = receivedMessageHashValues.contains(hashValue)
            receivedMessageHashValues.insert(hashValue)
            setReceivedMessageHashValues(to: receivedMessageHashValues)
            return !isDuplicate
        }
    }
    
    private static func parseProtoEnvelopes(from rawMessages: [JSON]) -> [SSKProtoEnvelope] {
        return rawMessages.compactMap { rawMessage in
            guard let base64EncodedData = rawMessage["data"] as? String, let data = Data(base64Encoded: base64EncodedData) else {
                print("[Loki] Failed to decode data for message: \(rawMessage).")
                return nil
            }
            guard let envelope = try? LokiMessageWrapper.unwrap(data: data) else {
                print("[Loki] Failed to unwrap data for message: \(rawMessage).")
                return nil
            }
            return envelope
        }
    }

    // MARK: Message Hash Caching
    private static func getLastMessageHashValue(for target: LokiAPITarget) -> String? {
        var result: String? = nil
        // Uses a read/write connection because getting the last message hash value also removes expired messages as needed
        // TODO: This shouldn't be the case; a getter shouldn't have an unexpected side effect
        storage.dbReadWriteConnection.readWrite { transaction in
            result = storage.getLastMessageHash(forServiceNode: target.address, transaction: transaction)
        }
        return result
    }

    private static func setLastMessageHashValue(for target: LokiAPITarget, hashValue: String, expirationDate: UInt64) {
        storage.dbReadWriteConnection.readWrite { transaction in
            storage.setLastMessageHash(forServiceNode: target.address, hash: hashValue, expiresAt: expirationDate, transaction: transaction)
        }
    }

    private static func getReceivedMessageHashValues() -> Set<String>? {
        var result: Set<String>? = nil
        storage.dbReadConnection.read { transaction in
            result = transaction.object(forKey: receivedMessageHashValuesKey, inCollection: receivedMessageHashValuesCollection) as! Set<String>?
        }
        return result
    }

    private static func setReceivedMessageHashValues(to receivedMessageHashValues: Set<String>) {
        storage.dbReadWriteConnection.readWrite { transaction in
            transaction.setObject(receivedMessageHashValues, forKey: receivedMessageHashValuesKey, inCollection: receivedMessageHashValuesCollection)
        }
    }
    
    // MARK: User ID Caching
    @objc public static func cache(_ userHexEncodedPublicKey: String, for threadID: String) {
        if let cache = userIDCache[threadID] {
            var mutableCache = cache
            mutableCache.insert(userHexEncodedPublicKey)
            userIDCache[threadID] = mutableCache
        } else {
            userIDCache[threadID] = [ userHexEncodedPublicKey ]
        }
    }
    
    @objc public static func getUserIDs(for query: String, in threadID: String) -> [String] {
        // Prepare
        guard let cache = userIDCache[threadID] else { return [] }
        var candidates: [(id: String, displayName: String)] = []
        // Gather candidates
        storage.dbReadConnection.read { transaction in
            let collection = "\(LokiGroupChatAPI.publicChatServer).\(LokiGroupChatAPI.publicChatServerID)"
            candidates = cache.flatMap { id in
                guard let displayName = transaction.object(forKey: id, inCollection: collection) as! String? else { return nil }
                return (id: id, displayName: displayName)
            }
        }
        // Sort alphabetically first
        candidates.sort { $0.displayName < $1.displayName }
        if query.count >= 2 {
            // Filter out any non-matching candidates
            candidates = candidates.filter { $0.displayName.lowercased().contains(query.lowercased()) }
            // Sort based on where in the candidate the query occurs
            candidates.sort {
                $0.displayName.lowercased().range(of: query.lowercased())!.lowerBound < $1.displayName.lowercased().range(of: query.lowercased())!.lowerBound
            }
        }
        // Return
        return candidates.map { $0.id } // Inefficient to do this and then look up the display name again later, but easy to interface with Obj-C
    }
    
    @objc public static func populateUserIDCacheIfNeeded(for threadID: String, in transaction: YapDatabaseReadWriteTransaction? = nil) {
        guard userIDCache[threadID] == nil else { return }
        var result: Set<String> = []
        func populate(in transaction: YapDatabaseReadWriteTransaction) {
            guard let thread = TSThread.fetch(uniqueId: threadID, transaction: transaction) else { return }
            let interactions = transaction.ext(TSMessageDatabaseViewExtensionName) as! YapDatabaseViewTransaction
            interactions.enumerateKeysAndObjects(inGroup: threadID) { _, _, object, index, _ in
                guard let message = object as? TSIncomingMessage, index < userIDScanLimit else { return }
                result.insert(message.authorId)
            }
        }
        if let transaction = transaction {
            populate(in: transaction)
        } else {
            storage.dbReadWriteConnection.readWrite { transaction in
                populate(in: transaction)
            }
        }
        result.insert(userHexEncodedPublicKey)
        userIDCache[threadID] = result
    }
}

// MARK: Error Handling
private extension Promise {

    fileprivate func recoveringNetworkErrorsIfNeeded() -> Promise<T> {
        return recover() { error -> Promise<T> in
            switch error {
            case NetworkManagerError.taskError(_, let underlyingError): throw underlyingError
            default: throw error
            }
        }
    }
}
