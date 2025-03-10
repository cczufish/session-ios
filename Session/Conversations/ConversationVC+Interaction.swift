import CoreServices
import Photos
import PhotosUI

extension ConversationVC : InputViewDelegate, MessageCellDelegate, ContextMenuActionDelegate, ScrollToBottomButtonDelegate,
    SendMediaNavDelegate, UIDocumentPickerDelegate, AttachmentApprovalViewControllerDelegate, GifPickerViewControllerDelegate,
    ConversationTitleViewDelegate {

    func handleTitleViewTapped() {
        openSettings()
    }
    
    @objc func openSettings() {
        let settingsVC = OWSConversationSettingsViewController()
        settingsVC.configure(with: thread, uiDatabaseConnection: OWSPrimaryStorage.shared().uiDatabaseConnection)
        settingsVC.conversationSettingsViewDelegate = self
        navigationController!.pushViewController(settingsVC, animated: true, completion: nil)
    }

    func handleScrollToBottomButtonTapped() {
        // The table view's content size is calculated by the estimated height of cells,
        // so the result may be inaccurate before all the cells are loaded. Use this
        // to scroll to the last row instead.
        let indexPath = IndexPath(row: viewItems.count - 1, section: 0)
        unreadViewItems.removeAll()
        messagesTableView.scrollToRow(at: indexPath, at: .top, animated: true)
    }

    // MARK: Blocking
    @objc func unblock() {
        guard let thread = thread as? TSContactThread else { return }
        let publicKey = thread.contactSessionID()
        UIView.animate(withDuration: 0.25, animations: {
            self.blockedBanner.alpha = 0
        }, completion: { _ in
            OWSBlockingManager.shared().removeBlockedPhoneNumber(publicKey)
        })
    }

    func showBlockedModalIfNeeded() -> Bool {
        guard let thread = thread as? TSContactThread else { return false }
        let publicKey = thread.contactSessionID()
        guard OWSBlockingManager.shared().isRecipientIdBlocked(publicKey) else { return false }
        let blockedModal = BlockedModal(publicKey: publicKey)
        blockedModal.modalPresentationStyle = .overFullScreen
        blockedModal.modalTransitionStyle = .crossDissolve
        present(blockedModal, animated: true, completion: nil)
        return true
    }

    // MARK: Attachments
    func sendMediaNavDidCancel(_ sendMediaNavigationController: SendMediaNavigationController) {
        dismiss(animated: true, completion: nil)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didApproveAttachments attachments: [SignalAttachment], messageText: String?) {
        sendAttachments(attachments, with: messageText ?? "")
        resetMentions()
        self.snInputView.text = ""
        dismiss(animated: true) { }
    }

    func sendMediaNavInitialMessageText(_ sendMediaNavigationController: SendMediaNavigationController) -> String? {
        return snInputView.text
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeMessageText newMessageText: String?) {
        snInputView.text = newMessageText ?? ""
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didApproveAttachments attachments: [SignalAttachment], messageText: String?) {
        sendAttachments(attachments, with: messageText ?? "")
        scrollToBottom(isAnimated: false)
        resetMentions()
        self.snInputView.text = ""
        dismiss(animated: true) { }
    }

    func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController) {
        dismiss(animated: true, completion: nil)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeMessageText newMessageText: String?) {
        snInputView.text = newMessageText ?? ""
    }

    func handleCameraButtonTapped() {
        guard requestCameraPermissionIfNeeded() else { return }
        requestMicrophonePermissionIfNeeded { }
        if AVAudioSession.sharedInstance().recordPermission != .granted {
            SNLog("Proceeding without microphone access. Any recorded video will be silent.")
        }
        let sendMediaNavController = SendMediaNavigationController.showingCameraFirst()
        sendMediaNavController.sendMediaNavDelegate = self
        sendMediaNavController.modalPresentationStyle = .fullScreen
        present(sendMediaNavController, animated: true, completion: nil)
    }
    
    func handleLibraryButtonTapped() {
        requestLibraryPermissionIfNeeded { [weak self] in
            DispatchQueue.main.async {
                let sendMediaNavController = SendMediaNavigationController.showingMediaLibraryFirst()
                sendMediaNavController.sendMediaNavDelegate = self
                sendMediaNavController.modalPresentationStyle = .fullScreen
                self?.present(sendMediaNavController, animated: true, completion: nil)
            }
        }
    }
    
    func handleGIFButtonTapped() {
        let gifVC = GifPickerViewController(thread: thread)
        gifVC.delegate = self
        let navController = OWSNavigationController(rootViewController: gifVC)
        navController.modalPresentationStyle = .fullScreen
        present(navController, animated: true) { }
    }

    func gifPickerDidSelect(attachment: SignalAttachment) {
        showAttachmentApprovalDialog(for: [ attachment ])
    }
    
    func handleDocumentButtonTapped() {
        // UIDocumentPickerModeImport copies to a temp file within our container.
        // It uses more memory than "open" but lets us avoid working with security scoped URLs.
        let documentPickerVC = UIDocumentPickerViewController(documentTypes: [ kUTTypeItem as String ], in: UIDocumentPickerMode.import)
        documentPickerVC.delegate = self
        documentPickerVC.modalPresentationStyle = .fullScreen
        SNAppearance.switchToDocumentPickerAppearance()
        present(documentPickerVC, animated: true, completion: nil)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        SNAppearance.switchToSessionAppearance() // Switch back to the correct appearance
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        SNAppearance.switchToSessionAppearance()
        guard let url = urls.first else { return } // TODO: Handle multiple?
        let urlResourceValues: URLResourceValues
        do {
            urlResourceValues = try url.resourceValues(forKeys: [ .typeIdentifierKey, .isDirectoryKey, .nameKey ])
        } catch {
            let alert = UIAlertController(title: "Session", message: "An error occurred.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            return present(alert, animated: true, completion: nil)
        }
        let type = urlResourceValues.typeIdentifier ?? (kUTTypeData as String)
        guard urlResourceValues.isDirectory != true else {
            DispatchQueue.main.async {
                let title = NSLocalizedString("ATTACHMENT_PICKER_DOCUMENTS_PICKED_DIRECTORY_FAILED_ALERT_TITLE", comment: "")
                let message = NSLocalizedString("ATTACHMENT_PICKER_DOCUMENTS_PICKED_DIRECTORY_FAILED_ALERT_BODY", comment: "")
                OWSAlerts.showAlert(title: title, message: message)
            }
            return
        }
        let fileName = urlResourceValues.name ?? NSLocalizedString("ATTACHMENT_DEFAULT_FILENAME", comment: "")
        guard let dataSource = DataSourcePath.dataSource(with: url, shouldDeleteOnDeallocation: false) else {
            DispatchQueue.main.async {
                let title = NSLocalizedString("ATTACHMENT_PICKER_DOCUMENTS_FAILED_ALERT_TITLE", comment: "")
                OWSAlerts.showAlert(title: title)
            }
            return
        }
        dataSource.sourceFilename = fileName
        // Although we want to be able to send higher quality attachments through the document picker
        // it's more imporant that we ensure the sent format is one all clients can accept (e.g. *not* quicktime .mov)
        guard !SignalAttachment.isInvalidVideo(dataSource: dataSource, dataUTI: type) else {
            return showAttachmentApprovalDialogAfterProcessingVideo(at: url, with: fileName)
        }
        // "Document picker" attachments _SHOULD NOT_ be resized
        let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: type, imageQuality: .original)
        showAttachmentApprovalDialog(for: [ attachment ])
    }

    func showAttachmentApprovalDialog(for attachments: [SignalAttachment]) {
        let navController = AttachmentApprovalViewController.wrappedInNavController(attachments: attachments, approvalDelegate: self)
        present(navController, animated: true, completion: nil)
    }

    func showAttachmentApprovalDialogAfterProcessingVideo(at url: URL, with fileName: String) {
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: true, message: nil) { [weak self] modalActivityIndicator in
            let dataSource = DataSourcePath.dataSource(with: url, shouldDeleteOnDeallocation: false)!
            dataSource.sourceFilename = fileName
            let compressionResult: SignalAttachment.VideoCompressionResult = SignalAttachment.compressVideoAsMp4(dataSource: dataSource, dataUTI: kUTTypeMPEG4 as String)
            compressionResult.attachmentPromise.done { attachment in
                guard !modalActivityIndicator.wasCancelled, let attachment = attachment as? SignalAttachment else { return }
                modalActivityIndicator.dismiss {
                    if !attachment.hasError {
                        self?.showAttachmentApprovalDialog(for: [ attachment ])
                    } else {
                        self?.showErrorAlert(for: attachment)
                    }
                }
            }.retainUntilComplete()
        }
    }

    // MARK: Message Sending
    func handleSendButtonTapped() {
        sendMessage()
    }

    func sendMessage(hasPermissionToSendSeed: Bool = false) {
        guard !showBlockedModalIfNeeded() else { return }
        let text = replaceMentions(in: snInputView.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let thread = self.thread
        guard !text.isEmpty else { return }
        if text.contains(mnemonic) && !thread.isNoteToSelf() && !hasPermissionToSendSeed {
            // Warn the user if they're about to send their seed to someone
            let modal = SendSeedModal()
            modal.modalPresentationStyle = .overFullScreen
            modal.modalTransitionStyle = .crossDissolve
            modal.proceed = { self.sendMessage(hasPermissionToSendSeed: true) }
            return present(modal, animated: true, completion: nil)
        }
        let message = VisibleMessage()
        message.sentTimestamp = NSDate.millisecondTimestamp()
        message.text = text
        message.quote = VisibleMessage.Quote.from(snInputView.quoteDraftInfo?.model)
        let linkPreviewDraft = snInputView.linkPreviewInfo?.draft
        let tsMessage = TSOutgoingMessage.from(message, associatedWith: thread)
        viewModel.appendUnsavedOutgoingTextMessage(tsMessage)
        Storage.write(with: { transaction in
            message.linkPreview = VisibleMessage.LinkPreview.from(linkPreviewDraft, using: transaction)
        }, completion: { [weak self] in
            tsMessage.linkPreview = OWSLinkPreview.from(message.linkPreview)
            Storage.shared.write(with: { transaction in
                tsMessage.save(with: transaction as! YapDatabaseReadWriteTransaction)
            }, completion: { [weak self] in
                // At this point the TSOutgoingMessage should have its link preview set, so we can scroll to the bottom knowing
                // the height of the new message cell
                self?.scrollToBottom(isAnimated: false)
            })
            Storage.shared.write { transaction in
                MessageSender.send(message, with: [], in: thread, using: transaction as! YapDatabaseReadWriteTransaction)
            }
            self?.handleMessageSent()
        })
    }

    func sendAttachments(_ attachments: [SignalAttachment], with text: String) {
        guard !showBlockedModalIfNeeded() else { return }
        for attachment in attachments {
            if attachment.hasError {
                return showErrorAlert(for: attachment)
            }
        }
        let thread = self.thread
        let message = VisibleMessage()
        message.sentTimestamp = NSDate.millisecondTimestamp()
        message.text = replaceMentions(in: text)
        let tsMessage = TSOutgoingMessage.from(message, associatedWith: thread)
        Storage.write(with: { transaction in
            tsMessage.save(with: transaction)
            // The new message cell is inserted at this point, but the TSOutgoingMessage doesn't have its attachment yet
        }, completion: { [weak self] in
            Storage.write(with: { transaction in
                MessageSender.send(message, with: attachments, in: thread, using: transaction)
            }, completion: { [weak self] in
                // At this point the TSOutgoingMessage should have its attachments set, so we can scroll to the bottom knowing
                // the height of the new message cell
                self?.scrollToBottom(isAnimated: false)
            })
            self?.handleMessageSent()
        })
    }

    func handleMessageSent() {
        resetMentions()
        self.snInputView.text = ""
        self.snInputView.quoteDraftInfo = nil
        self.markAllAsRead()
        if Environment.shared.preferences.soundInForeground() {
            let soundID = OWSSounds.systemSoundID(for: .messageSent, quiet: true)
            AudioServicesPlaySystemSound(soundID)
        }
        SSKEnvironment.shared.typingIndicators.didSendOutgoingMessage(inThread: thread)
        Storage.write { transaction in
            self.thread.setDraft("", transaction: transaction)
        }
    }

    // MARK: Input View
    func inputTextViewDidChangeContent(_ inputTextView: InputTextView) {
        let newText = inputTextView.text ?? ""
        if !newText.isEmpty {
            SSKEnvironment.shared.typingIndicators.didStartTypingOutgoingInput(inThread: thread)
        }
        updateMentions(for: newText)
    }

    func showLinkPreviewSuggestionModal() {
        let linkPreviewModel = LinkPreviewModal() { [weak self] in
            self?.snInputView.autoGenerateLinkPreview()
        }
        linkPreviewModel.modalPresentationStyle = .overFullScreen
        linkPreviewModel.modalTransitionStyle = .crossDissolve
        present(linkPreviewModel, animated: true, completion: nil)
    }

    // MARK: Mentions
    func updateMentions(for newText: String) {
        if newText.count < oldText.count {
            currentMentionStartIndex = nil
            snInputView.hideMentionsUI()
            mentions = mentions.filter { $0.isContained(in: newText) }
        }
        if !newText.isEmpty {
            let lastCharacterIndex = newText.index(before: newText.endIndex)
            let lastCharacter = newText[lastCharacterIndex]
            // Check if there is whitespace before the '@' or the '@' is the first character
            let isCharacterBeforeLastWhiteSpaceOrStartOfLine: Bool
            if newText.count == 1 {
                isCharacterBeforeLastWhiteSpaceOrStartOfLine = true // Start of line
            } else {
                let characterBeforeLast = newText[newText.index(before: lastCharacterIndex)]
                isCharacterBeforeLastWhiteSpaceOrStartOfLine = characterBeforeLast.isWhitespace
            }
            if lastCharacter == "@" && isCharacterBeforeLastWhiteSpaceOrStartOfLine {
                let candidates = MentionsManager.getMentionCandidates(for: "", in: thread.uniqueId!)
                currentMentionStartIndex = lastCharacterIndex
                snInputView.showMentionsUI(for: candidates, in: thread)
            } else if lastCharacter.isWhitespace || lastCharacter == "@" { // the lastCharacter == "@" is to check for @@
                currentMentionStartIndex = nil
                snInputView.hideMentionsUI()
            } else {
                if let currentMentionStartIndex = currentMentionStartIndex {
                    let query = String(newText[newText.index(after: currentMentionStartIndex)...]) // + 1 to get rid of the @
                    let candidates = MentionsManager.getMentionCandidates(for: query, in: thread.uniqueId!)
                    snInputView.showMentionsUI(for: candidates, in: thread)
                }
            }
        }
        oldText = newText
    }

    func resetMentions() {
        oldText = ""
        currentMentionStartIndex = nil
        mentions = []
    }

    func replaceMentions(in text: String) -> String {
        var result = text
        for mention in mentions {
            guard let range = result.range(of: "@\(mention.displayName)") else { continue }
            result = result.replacingCharacters(in: range, with: "@\(mention.publicKey)")
        }
        return result
    }

    func handleMentionSelected(_ mention: Mention, from view: MentionSelectionView) {
        guard let currentMentionStartIndex = currentMentionStartIndex else { return }
        mentions.append(mention)
        let oldText = snInputView.text
        let newText = oldText.replacingCharacters(in: currentMentionStartIndex..., with: "@\(mention.displayName)")
        snInputView.text = newText
        self.currentMentionStartIndex = nil
        snInputView.hideMentionsUI()
        self.oldText = newText
    }

    // MARK: View Item Interaction
    func handleViewItemLongPressed(_ viewItem: ConversationViewItem) {
        // Show the context menu if applicable
        guard let index = viewItems.firstIndex(where: { $0 === viewItem }),
            let cell = messagesTableView.cellForRow(at: IndexPath(row: index, section: 0)) as? VisibleMessageCell,
            let snapshot = cell.bubbleView.snapshotView(afterScreenUpdates: false), contextMenuWindow == nil,
            !ContextMenuVC.actions(for: viewItem, delegate: self).isEmpty else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        let frame = cell.convert(cell.bubbleView.frame, to: UIApplication.shared.keyWindow!)
        let window = ContextMenuWindow()
        let contextMenuVC = ContextMenuVC(snapshot: snapshot, viewItem: viewItem, frame: frame, delegate: self) { [weak self] in
            window.isHidden = true
            guard let self = self else { return }
            self.contextMenuVC = nil
            self.contextMenuWindow = nil
            self.scrollButton.alpha = 0
            UIView.animate(withDuration: 0.25) {
                self.scrollButton.alpha = self.getScrollButtonOpacity()
                self.unreadCountView.alpha = self.scrollButton.alpha
            }
        }
        self.contextMenuVC = contextMenuVC
        contextMenuWindow = window
        window.rootViewController = contextMenuVC
        window.makeKeyAndVisible()
        window.backgroundColor = .clear
    }

    func handleViewItemTapped(_ viewItem: ConversationViewItem, gestureRecognizer: UITapGestureRecognizer) {
        func confirmDownload() {
            let modal = DownloadAttachmentModal(viewItem: viewItem)
            modal.modalPresentationStyle = .overFullScreen
            modal.modalTransitionStyle = .crossDissolve
            present(modal, animated: true, completion: nil)
        }
        if let message = viewItem.interaction as? TSOutgoingMessage, message.messageState == .failed {
            // Show the failed message sheet
            showFailedMessageSheet(for: message)
        } else {
            switch viewItem.messageCellType {
            case .audio:
                if viewItem.interaction is TSIncomingMessage,
                    let thread = self.thread as? TSContactThread,
                    Storage.shared.getContact(with: thread.contactSessionID())?.isTrusted != true {
                    confirmDownload()
                } else {
                    playOrPauseAudio(for: viewItem)
                }
            case .mediaMessage:
                guard let index = viewItems.firstIndex(where: { $0 === viewItem }),
                    let cell = messagesTableView.cellForRow(at: IndexPath(row: index, section: 0)) as? VisibleMessageCell else { return }
                if viewItem.interaction is TSIncomingMessage,
                    let thread = self.thread as? TSContactThread,
                    Storage.shared.getContact(with: thread.contactSessionID())?.isTrusted != true {
                    confirmDownload()
                } else {
                    guard let albumView = cell.albumView else { return }
                    let locationInCell = gestureRecognizer.location(in: cell)
                    // Figure out whether the "read more" button was tapped
                    if let overlayView = cell.mediaTextOverlayView {
                        let locationInOverlayView = cell.convert(locationInCell, to: overlayView)
                        if let readMoreButton = overlayView.readMoreButton, readMoreButton.frame.contains(locationInOverlayView) {
                            return showFullText(viewItem) // HACK: This is a dirty way to do this
                        }
                    }
                    // Otherwise, figure out which of the media views was tapped
                    let locationInAlbumView = cell.convert(locationInCell, to: albumView)
                    guard let mediaView = albumView.mediaView(forLocation: locationInAlbumView) else { return }
                    if albumView.isMoreItemsView(mediaView: mediaView) && viewItem.mediaAlbumHasFailedAttachment() {
                        // TODO: Tapped a failed incoming attachment
                    }
                    let attachment = mediaView.attachment
                    if let pointer = attachment as? TSAttachmentPointer {
                        if pointer.state == .failed {
                            // TODO: Tapped a failed incoming attachment
                        }
                    }
                    guard let stream = attachment as? TSAttachmentStream else { return }
                    let gallery = MediaGallery(thread: thread, options: [ .sliderEnabled, .showAllMediaButton ])
                    gallery.presentDetailView(fromViewController: self, mediaAttachment: stream)
                }
            case .genericAttachment:
                if viewItem.interaction is TSIncomingMessage,
                    let thread = self.thread as? TSContactThread,
                    Storage.shared.getContact(with: thread.contactSessionID())?.isTrusted != true {
                    confirmDownload()
                } else {
                    // Open the document if possible
                    guard let url = viewItem.attachmentStream?.originalMediaURL else { return }
                    let shareVC = UIActivityViewController(activityItems: [ url ], applicationActivities: nil)
                    navigationController!.present(shareVC, animated: true, completion: nil)
                }
            case .textOnlyMessage:
                if let preview = viewItem.linkPreview, let urlAsString = preview.urlString, let url = URL(string: urlAsString) {
                    // Open the link preview URL
                    openURL(url)
                } else if let reply = viewItem.quotedReply {
                    // Scroll to the source of the reply
                    guard let indexPath = viewModel.ensureLoadWindowContainsQuotedReply(reply) else { return }
                    messagesTableView.scrollToRow(at: indexPath, at: UITableView.ScrollPosition.middle, animated: true)
                } else if let message = viewItem.interaction as? TSIncomingMessage, let name = message.openGroupInvitationName,
                    let url = message.openGroupInvitationURL {
                    joinOpenGroup(name: name, url: url)
                }
            default: break
            }
        }
    }
    
    func handleViewItemSwiped(_ viewItem: ConversationViewItem, state: SwipeState) {
        switch state {
        case .began:
            messagesTableView.isScrollEnabled = false
        case .ended, .cancelled:
            messagesTableView.isScrollEnabled = true
        }
    }

    func showFailedMessageSheet(for tsMessage: TSOutgoingMessage) {
        let thread = self.thread
        let error = tsMessage.mostRecentFailureText
        let sheet = UIAlertController(title: error, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
            Storage.write { transaction in
                tsMessage.remove(with: transaction)
                Storage.shared.cancelPendingMessageSendJobIfNeeded(for: tsMessage.timestamp, using: transaction)
            }
        }))
        sheet.addAction(UIAlertAction(title: "Resend", style: .default, handler: { _ in
            let message = VisibleMessage.from(tsMessage)
            Storage.write { transaction in
                var attachments: [TSAttachmentStream] = []
                tsMessage.attachmentIds.forEach { attachmentID in
                    guard let attachmentID = attachmentID as? String else { return }
                    let attachment = TSAttachment.fetch(uniqueId: attachmentID, transaction: transaction)
                    guard let stream = attachment as? TSAttachmentStream else { return }
                    attachments.append(stream)
                }
                MessageSender.prep(attachments, for: message, using: transaction)
                MessageSender.send(message, in: thread, using: transaction)
            }
        }))
        // HACK: Extracting this info from the error string is pretty dodgy
        let prefix = "HTTP request failed at destination (Service node "
        if error.hasPrefix(prefix) {
            let rest = error.substring(from: prefix.count)
            if let index = rest.firstIndex(of: ")") {
                let snodeAddress = String(rest[rest.startIndex..<index])
                sheet.addAction(UIAlertAction(title: "Copy Service Node Info", style: .default, handler: { _ in
                    UIPasteboard.general.string = snodeAddress
                }))
            }
        }
        present(sheet, animated: true, completion: nil)
    }

    func handleViewItemDoubleTapped(_ viewItem: ConversationViewItem) {
        switch viewItem.messageCellType {
        case .audio: speedUpAudio(for: viewItem) // The user can double tap a voice message when it's playing to speed it up
        default: break
        }
    }
    
    func showFullText(_ viewItem: ConversationViewItem) {
        let longMessageVC = LongTextViewController(viewItem: viewItem)
        navigationController!.pushViewController(longMessageVC, animated: true)
    }
    
    func reply(_ viewItem: ConversationViewItem) {
        var quoteDraftOrNil: OWSQuotedReplyModel?
        Storage.read { transaction in
            quoteDraftOrNil = OWSQuotedReplyModel.quotedReplyForSending(with: viewItem, threadId: viewItem.interaction.uniqueThreadId, transaction: transaction)
        }
        guard let quoteDraft = quoteDraftOrNil else { return }
        let isOutgoing = (viewItem.interaction.interactionType() == .outgoingMessage)
        snInputView.quoteDraftInfo = (model: quoteDraft, isOutgoing: isOutgoing)
        snInputView.becomeFirstResponder()
    }
    
    func copy(_ viewItem: ConversationViewItem) {
        if viewItem.canCopyMedia() {
            viewItem.copyMediaAction()
        } else {
            viewItem.copyTextAction()
        }
    }
    
    func copySessionID(_ viewItem: ConversationViewItem) {
        // FIXME: Copying media
        guard let message = viewItem.interaction as? TSIncomingMessage else { return }
        UIPasteboard.general.string = message.authorId
    }
    
    func delete(_ viewItem: ConversationViewItem) {
        if (!self.isUnsendRequestsEnabled) {
            viewItem.deleteAction()
            return
        }
        
        func showInputAccessoryView() {
            UIView.animate(withDuration: 0.25, animations: {
                self.inputAccessoryView?.isHidden = false
                self.inputAccessoryView?.alpha = 1
            })
        }
        
        if viewItem.interaction.interactionType() == .outgoingMessage,
           let message = viewItem.interaction as? TSMessage, message.serverHash != nil  {
            let alertVC = UIAlertController.init(title: nil, message: nil, preferredStyle: .actionSheet)
            let deleteLocallyAction = UIAlertAction.init(title: NSLocalizedString("delete_message_for_me", comment: ""), style: .destructive) { _ in
                self.deleteLocally(viewItem)
                showInputAccessoryView()
            }
            alertVC.addAction(deleteLocallyAction)
            
            var title = NSLocalizedString("delete_message_for_everyone", comment: "")
            if !viewItem.isGroupThread {
                title = String(format: NSLocalizedString("delete_message_for_me_and_recipient", comment: ""), viewItem.interaction.thread.name())
            }
            let deleteRemotelyAction = UIAlertAction.init(title: title, style: .destructive) { _ in
                self.deleteForEveryone(viewItem)
                showInputAccessoryView()
            }
            alertVC.addAction(deleteRemotelyAction)
            
            let cancelAction = UIAlertAction.init(title: NSLocalizedString("TXT_CANCEL_TITLE", comment: ""), style: .cancel) {_ in
                showInputAccessoryView()
            }
            alertVC.addAction(cancelAction)
            
            self.inputAccessoryView?.isHidden = true
            self.inputAccessoryView?.alpha = 0
            self.presentAlert(alertVC)
        } else {
            deleteLocally(viewItem)
        }
    }
    
    private func buildUnsendRequest(_ viewItem: ConversationViewItem) -> UnsendRequest? {
        if let message = viewItem.interaction as? TSMessage,
           message.isOpenGroupMessage || message.serverHash == nil { return nil }
        let unsendRequest = UnsendRequest()
        switch viewItem.interaction.interactionType() {
        case .incomingMessage:
            if let incomingMessage = viewItem.interaction as? TSIncomingMessage {
                unsendRequest.author = incomingMessage.authorId
            }
        case .outgoingMessage: unsendRequest.author = getUserHexEncodedPublicKey()
        default: return nil // Should never occur
        }
        unsendRequest.timestamp = viewItem.interaction.timestamp
        return unsendRequest
    }
    
    func deleteLocally(_ viewItem: ConversationViewItem) {
        viewItem.deleteLocallyAction()
        if let unsendRequest = buildUnsendRequest(viewItem) {
            SNMessagingKitConfiguration.shared.storage.write { transaction in
                MessageSender.send(unsendRequest, to: .contact(publicKey: getUserHexEncodedPublicKey()), using: transaction).retainUntilComplete()
            }
        }
    }
    
    func deleteForEveryone(_ viewItem: ConversationViewItem) {
        viewItem.deleteLocallyAction()
        viewItem.deleteRemotelyAction()
        if let unsendRequest = buildUnsendRequest(viewItem) {
            SNMessagingKitConfiguration.shared.storage.write { transaction in
                MessageSender.send(unsendRequest, in: self.thread, using: transaction as! YapDatabaseReadWriteTransaction)
            }
        }
    }
    
    func save(_ viewItem: ConversationViewItem) {
        guard viewItem.canSaveMedia() else { return }
        viewItem.saveMediaAction()
        sendMediaSavedNotificationIfNeeded(for: viewItem)
    }
    
    func ban(_ viewItem: ConversationViewItem) {
        guard let message = viewItem.interaction as? TSIncomingMessage, message.isOpenGroupMessage else { return }
        let explanation = "This will ban the selected user from this room. It won't ban them from other rooms."
        let alert = UIAlertController(title: "Session", message: explanation, preferredStyle: .alert)
        let threadID = thread.uniqueId!
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            let publicKey = message.authorId
            guard let openGroupV2 = Storage.shared.getV2OpenGroup(for: threadID) else { return }
            OpenGroupAPIV2.ban(publicKey, from: openGroupV2.room, on: openGroupV2.server).retainUntilComplete()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }
    
    func banAndDeleteAllMessages(_ viewItem: ConversationViewItem) {
        guard let message = viewItem.interaction as? TSIncomingMessage, message.isOpenGroupMessage else { return }
        let explanation = "This will ban the selected user from this room and delete all messages sent by them. It won't ban them from other rooms or delete the messages they sent there."
        let alert = UIAlertController(title: "Session", message: explanation, preferredStyle: .alert)
        let threadID = thread.uniqueId!
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            let publicKey = message.authorId
            guard let openGroupV2 = Storage.shared.getV2OpenGroup(for: threadID) else { return }
            OpenGroupAPIV2.banAndDeleteAllMessages(publicKey, from: openGroupV2.room, on: openGroupV2.server).retainUntilComplete()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    func handleQuoteViewCancelButtonTapped() {
        snInputView.quoteDraftInfo = nil
    }
    
    func openURL(_ url: URL) {
        // URLs can be unsafe, so always ask the user whether they want to open one
        let urlModal = URLModal(url: url)
        urlModal.modalPresentationStyle = .overFullScreen
        urlModal.modalTransitionStyle = .crossDissolve
        present(urlModal, animated: true, completion: nil)
    }
    
    func joinOpenGroup(name: String, url: String) {
        // Open groups can be unsafe, so always ask the user whether they want to join one
        let joinOpenGroupModal = JoinOpenGroupModal(name: name, url: url)
        joinOpenGroupModal.modalPresentationStyle = .overFullScreen
        joinOpenGroupModal.modalTransitionStyle = .crossDissolve
        present(joinOpenGroupModal, animated: true, completion: nil)
    }
    
    func handleReplyButtonTapped(for viewItem: ConversationViewItem) {
        reply(viewItem)
    }
    
    func showUserDetails(for sessionID: String) {
        let userDetailsSheet = UserDetailsSheet(for: sessionID)
        userDetailsSheet.modalPresentationStyle = .overFullScreen
        userDetailsSheet.modalTransitionStyle = .crossDissolve
        present(userDetailsSheet, animated: true, completion: nil)
    }

    // MARK: Voice Message Playback
    @objc func handleAudioDidFinishPlayingNotification(_ notification: Notification) {
        // Play the next voice message if there is one
        guard let audioPlayer = audioPlayer, let viewItem = audioPlayer.owner as? ConversationViewItem,
            let index = viewItems.firstIndex(where: { $0 === viewItem }), index < (viewItems.endIndex - 1) else { return }
        let nextViewItem = viewItems[index + 1]
        guard nextViewItem.messageCellType == .audio else { return }
        playOrPauseAudio(for: nextViewItem)
    }
    
    func playOrPauseAudio(for viewItem: ConversationViewItem) {
        guard let attachment = viewItem.attachmentStream else { return }
        let fileManager = FileManager.default
        guard let path = attachment.originalFilePath, fileManager.fileExists(atPath: path),
            let url = attachment.originalMediaURL else { return }
        if let audioPlayer = audioPlayer {
            if let owner = audioPlayer.owner as? ConversationViewItem, owner === viewItem {
                audioPlayer.playbackRate = 1
                audioPlayer.togglePlayState()
                return
            } else {
                audioPlayer.stop()
                self.audioPlayer = nil
            }
        }
        let audioPlayer = OWSAudioPlayer(mediaUrl: url, audioBehavior: .audioMessagePlayback, delegate: viewItem)
        self.audioPlayer = audioPlayer
        audioPlayer.owner = viewItem
        audioPlayer.play()
        audioPlayer.setCurrentTime(Double(viewItem.audioProgressSeconds))
    }

    func speedUpAudio(for viewItem: ConversationViewItem) {
        guard let audioPlayer = audioPlayer, let owner = audioPlayer.owner as? ConversationViewItem, owner === viewItem, audioPlayer.isPlaying else { return }
        audioPlayer.playbackRate = 1.5
        viewItem.lastAudioMessageView?.showSpeedUpLabel()
    }

    // MARK: Voice Message Recording
    func startVoiceMessageRecording() {
        // Request permission if needed
        requestMicrophonePermissionIfNeeded() { [weak self] in
            self?.cancelVoiceMessageRecording()
        }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else { return }
        // Cancel any current audio playback
        audioPlayer?.stop()
        audioPlayer = nil
        // Create URL
        let directory = OWSTemporaryDirectory()
        let fileName = "\(NSDate.millisecondTimestamp()).m4a"
        let path = (directory as NSString).appendingPathComponent(fileName)
        let url = URL(fileURLWithPath: path)
        // Set up audio session
        let isConfigured = audioSession.startAudioActivity(recordVoiceMessageActivity)
        guard isConfigured else {
            return cancelVoiceMessageRecording()
        }
        // Set up audio recorder
        let settings: [String:NSNumber] = [
            AVFormatIDKey : NSNumber(value: kAudioFormatMPEG4AAC),
            AVSampleRateKey : NSNumber(value: 44100),
            AVNumberOfChannelsKey : NSNumber(value: 2),
            AVEncoderBitRateKey : NSNumber(value: 128 * 1024)
        ]
        let audioRecorder: AVAudioRecorder
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder.isMeteringEnabled = true
            self.audioRecorder = audioRecorder
        } catch {
            SNLog("Couldn't start audio recording due to error: \(error).")
            return cancelVoiceMessageRecording()
        }
        // Limit voice messages to a minute
        audioTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false, block: { [weak self] _ in
            self?.snInputView.hideVoiceMessageUI()
            self?.endVoiceMessageRecording()
        })
        // Prepare audio recorder
        guard audioRecorder.prepareToRecord() else {
            SNLog("Couldn't prepare audio recorder.")
            return cancelVoiceMessageRecording()
        }
        // Start recording
        guard audioRecorder.record() else {
            SNLog("Couldn't record audio.")
            return cancelVoiceMessageRecording()
        }
    }

    func endVoiceMessageRecording() {
        // Hide the UI
        snInputView.hideVoiceMessageUI()
        // Cancel the timer
        audioTimer?.invalidate()
        // Check preconditions
        guard let audioRecorder = audioRecorder else { return }
        // Get duration
        let duration = audioRecorder.currentTime
        // Stop the recording
        stopVoiceMessageRecording()
        // Check for user misunderstanding
        guard duration > 1 else {
            self.audioRecorder = nil
            let title = NSLocalizedString("VOICE_MESSAGE_TOO_SHORT_ALERT_TITLE", comment: "")
            let message = NSLocalizedString("VOICE_MESSAGE_TOO_SHORT_ALERT_MESSAGE", comment: "")
            return OWSAlerts.showAlert(title: title, message: message)
        }
        // Get data
        let dataSourceOrNil = DataSourcePath.dataSource(with: audioRecorder.url, shouldDeleteOnDeallocation: true)
        self.audioRecorder = nil
        guard let dataSource = dataSourceOrNil else { return SNLog("Couldn't load recorded data.") }
        // Create attachment
        let fileName = (NSLocalizedString("VOICE_MESSAGE_FILE_NAME", comment: "") as NSString).appendingPathExtension("m4a")
        dataSource.sourceFilename = fileName
        let attachment = SignalAttachment.voiceMessageAttachment(dataSource: dataSource, dataUTI: kUTTypeMPEG4Audio as String)
        guard !attachment.hasError else {
            return showErrorAlert(for: attachment)
        }
        // Send attachment
        sendAttachments([ attachment ], with: "")
    }

    func cancelVoiceMessageRecording() {
        snInputView.hideVoiceMessageUI()
        audioTimer?.invalidate()
        stopVoiceMessageRecording()
        audioRecorder = nil
    }

    func stopVoiceMessageRecording() {
        audioRecorder?.stop()
        audioSession.endAudioActivity(recordVoiceMessageActivity)
    }
    
    // MARK: Data Extraction Notifications
    @objc func sendScreenshotNotificationIfNeeded() {
        /*
        guard thread is TSContactThread else { return }
        let message = DataExtractionNotification()
        message.kind = .screenshot
        Storage.write { transaction in
            MessageSender.send(message, in: self.thread, using: transaction)
        }
         */
    }
    
    func sendMediaSavedNotificationIfNeeded(for viewItem: ConversationViewItem) {
        guard thread is TSContactThread, viewItem.interaction.interactionType() == .incomingMessage else { return }
        let message = DataExtractionNotification()
        message.kind = .mediaSaved(timestamp: viewItem.interaction.timestamp)
        Storage.write { transaction in
            MessageSender.send(message, in: self.thread, using: transaction)
        }
    }

    // MARK: Requesting Permission
    func requestCameraPermissionIfNeeded() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .denied, .restricted:
            let modal = PermissionMissingModal(permission: "camera") { }
            modal.modalPresentationStyle = .overFullScreen
            modal.modalTransitionStyle = .crossDissolve
            present(modal, animated: true, completion: nil)
            return false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { _ in })
            return false
        default: return false
        }
    }

    func requestMicrophonePermissionIfNeeded(onNotGranted: @escaping () -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: break
        case .denied:
            onNotGranted()
            let modal = PermissionMissingModal(permission: "microphone") {
                onNotGranted()
            }
            modal.modalPresentationStyle = .overFullScreen
            modal.modalTransitionStyle = .crossDissolve
            present(modal, animated: true, completion: nil)
        case .undetermined:
            onNotGranted()
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        default: break
        }
    }

    func requestLibraryPermissionIfNeeded(onAuthorized: @escaping () -> Void) {
        let authorizationStatus: PHAuthorizationStatus
        if #available(iOS 14, *) {
            authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authorizationStatus == .notDetermined {
                // When the user chooses to select photos (which is the .limit status),
                // the PHPhotoUI will present the picker view on the top of the front view.
                // Since we have the ScreenLockUI showing when we request premissions,
                // the picker view will be presented on the top of the ScreenLockUI.
                // However, the ScreenLockUI will dismiss with the permission request alert view, so
                // the picker view then will dismiss, too. The selection process cannot be finished
                // this way. So we add a flag (isRequestingPermission) to prevent the ScreenLockUI
                // from showing when we request the photo library permission.
                Environment.shared.isRequestingPermission = true
                let appMode = AppModeManager.shared.currentAppMode
                // FIXME: Rather than setting the app mode to light and then to dark again once we're done,
                // it'd be better to just customize the appearance of the image picker. There doesn't currently
                // appear to be a good way to do so though...
                AppModeManager.shared.setCurrentAppMode(to: .light)
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    DispatchQueue.main.async {
                        AppModeManager.shared.setCurrentAppMode(to: appMode)
                    }
                    Environment.shared.isRequestingPermission = false
                    if [ PHAuthorizationStatus.authorized, PHAuthorizationStatus.limited ].contains(status) {
                        onAuthorized()
                    }
                }
            }
        } else {
            authorizationStatus = PHPhotoLibrary.authorizationStatus()
            if authorizationStatus == .notDetermined {
                PHPhotoLibrary.requestAuthorization { status in
                    if status == .authorized {
                        onAuthorized()
                    }
                }
            }
        }
        switch authorizationStatus {
        case .authorized, .limited:
            onAuthorized()
        case .denied, .restricted:
            let modal = PermissionMissingModal(permission: "library") { }
            modal.modalPresentationStyle = .overFullScreen
            modal.modalTransitionStyle = .crossDissolve
            present(modal, animated: true, completion: nil)
        default: return
        }
    }

    // MARK: Convenience
    func showErrorAlert(for attachment: SignalAttachment) {
        let title = NSLocalizedString("ATTACHMENT_ERROR_ALERT_TITLE", comment: "")
        let message = attachment.localizedErrorDescription ?? SignalAttachment.missingDataErrorMessage
        OWSAlerts.showAlert(title: title, message: message)
    }
}
