
@objc(LKGroupChatPoller)
public final class GroupChatPoller : NSObject {
    private let group: LokiGroupChat
    private var pollForNewMessagesTimer: Timer? = nil
    private var pollForDeletedMessagesTimer: Timer? = nil
    private var pollForModeratorsTimer: Timer? = nil
    private var hasStarted = false
    private let userHexEncodedPublicKey = OWSIdentityManager.shared().identityKeyPair()!.hexEncodedPublicKey
    
    // MARK: Settings
    private let pollForNewMessagesInterval: TimeInterval = 4
    private let pollForDeletedMessagesInterval: TimeInterval = 20
    private let pollForModeratorsInterval: TimeInterval = 10 * 60
    
    // MARK: Lifecycle
    @objc(initForGroup:)
    public init(for group: LokiGroupChat) {
        self.group = group
        super.init()
    }
    
    @objc public func startIfNeeded() {
        if hasStarted { return }
        pollForNewMessagesTimer = Timer.scheduledTimer(withTimeInterval: pollForNewMessagesInterval, repeats: true) { [weak self] _ in self?.pollForNewMessages() }
        pollForDeletedMessagesTimer = Timer.scheduledTimer(withTimeInterval: pollForDeletedMessagesInterval, repeats: true) { [weak self] _ in self?.pollForDeletedMessages() }
        pollForModeratorsTimer = Timer.scheduledTimer(withTimeInterval: pollForModeratorsInterval, repeats: true) { [weak self] _ in self?.pollForModerators() }
        // Perform initial updates
        pollForNewMessages()
        pollForDeletedMessages()
        pollForModerators()
        hasStarted = true
    }
    
    @objc public func stop() {
        pollForNewMessagesTimer?.invalidate()
        pollForDeletedMessagesTimer?.invalidate()
        pollForModeratorsTimer?.invalidate()
        hasStarted = false
    }
    
    // MARK: Polling
    private func pollForNewMessages() {
        // Prepare
        let group = self.group
        let userHexEncodedPublicKey = self.userHexEncodedPublicKey
        // Processing logic for incoming messages
        func processIncomingMessage(_ message: LokiGroupMessage) {
            let senderHexEncodedPublicKey = message.hexEncodedPublicKey
            let endIndex = senderHexEncodedPublicKey.endIndex
            let cutoffIndex = senderHexEncodedPublicKey.index(endIndex, offsetBy: -8)
            let senderDisplayName = "\(message.displayName) (...\(senderHexEncodedPublicKey[cutoffIndex..<endIndex]))"
            let id = group.id.data(using: String.Encoding.utf8)!
            let groupContext = SSKProtoGroupContext.builder(id: id, type: .deliver)
            groupContext.setName(group.displayName)
            let dataMessage = SSKProtoDataMessage.builder()
            dataMessage.setTimestamp(message.timestamp)
            dataMessage.setGroup(try! groupContext.build())
            if let quote = message.quote {
                let signalQuote = SSKProtoDataMessageQuote.builder(id: quote.quotedMessageTimestamp, author: quote.quoteeHexEncodedPublicKey)
                signalQuote.setText(quote.quotedMessageBody)
                dataMessage.setQuote(try! signalQuote.build())
            }
            dataMessage.setBody(message.body)
            if let messageServerID = message.serverID {
                let publicChatInfo = SSKProtoPublicChatInfo.builder()
                publicChatInfo.setServerID(messageServerID)
                dataMessage.setPublicChatInfo(try! publicChatInfo.build())
            }
            let content = SSKProtoContent.builder()
            content.setDataMessage(try! dataMessage.build())
            let envelope = SSKProtoEnvelope.builder(type: .ciphertext, timestamp: message.timestamp)
            envelope.setSource(senderHexEncodedPublicKey)
            envelope.setSourceDevice(OWSDevicePrimaryDeviceId)
            envelope.setContent(try! content.build().serializedData())
            let storage = OWSPrimaryStorage.shared()
            storage.dbReadWriteConnection.readWrite { transaction in
                transaction.setObject(senderDisplayName, forKey: senderHexEncodedPublicKey, inCollection: group.id)
                SSKEnvironment.shared.messageManager.throws_processEnvelope(try! envelope.build(), plaintextData: try! content.build().serializedData(), wasReceivedByUD: false, transaction: transaction)
            }
        }
        // Processing logic for outgoing messages
        func processOutgoingMessage(_ message: LokiGroupMessage) {
            guard let messageServerID = message.serverID else { return }
            let storage = OWSPrimaryStorage.shared()
            var isDuplicate = false
            storage.dbReadConnection.read { transaction in
                let id = storage.getIDForMessage(withServerID: UInt(messageServerID), in: transaction)
                isDuplicate = id != nil
            }
            guard !isDuplicate else { return }
            guard let groupID = group.id.data(using: .utf8) else { return }
            let thread = TSGroupThread.getOrCreateThread(withGroupId: groupID)
            let signalQuote: TSQuotedMessage?
            if let quote = message.quote {
                signalQuote = TSQuotedMessage(timestamp: quote.quotedMessageTimestamp, authorId: quote.quoteeHexEncodedPublicKey, body: quote.quotedMessageBody, quotedAttachmentsForSending: [])
            } else {
                signalQuote = nil
            }
            let message = TSOutgoingMessage(outgoingMessageWithTimestamp: message.timestamp, in: thread, messageBody: message.body, attachmentIds: [], expiresInSeconds: 0,
                expireStartedAt: 0, isVoiceMessage: false, groupMetaMessage: .deliver, quotedMessage: signalQuote, contactShare: nil, linkPreview: nil)
            storage.dbReadWriteConnection.readWrite { transaction in
                message.update(withSentRecipient: group.server, wasSentByUD: false, transaction: transaction)
                message.saveGroupChatMessageID(messageServerID, in: transaction)
                guard let messageID = message.uniqueId else { return print("[Loki] Failed to save group message.") }
                storage.setIDForMessageWithServerID(UInt(messageServerID), to: messageID, in: transaction)
            }
            if let linkPreviewURL = OWSLinkPreview.previewUrl(forMessageBodyText: message.body, selectedRange: nil) {
                message.generateLinkPreviewIfNeeded(fromURL: linkPreviewURL)
            }
        }
        // Poll
        let _ = LokiGroupChatAPI.getMessages(for: group.serverID, on: group.server).done(on: .main) { messages in
            messages.forEach { message in
                if message.hexEncodedPublicKey != userHexEncodedPublicKey {
                    processIncomingMessage(message)
                } else {
                    processOutgoingMessage(message)
                }
            }
        }
    }
    
    private func pollForDeletedMessages() {
        let group = self.group
        let _ = LokiGroupChatAPI.getDeletedMessageServerIDs(for: group.serverID, on: group.server).done { deletedMessageServerIDs in
            let storage = OWSPrimaryStorage.shared()
            storage.dbReadWriteConnection.readWrite { transaction in
                let deletedMessageIDs = deletedMessageServerIDs.compactMap { storage.getIDForMessage(withServerID: UInt($0), in: transaction) }
                deletedMessageIDs.forEach { messageID in
                    TSMessage.fetch(uniqueId: messageID)?.remove(with: transaction)
                }
            }
        }
    }
    
    private func pollForModerators() {
        let _ = LokiGroupChatAPI.getModerators(for: group.serverID, on: group.server)
    }
}