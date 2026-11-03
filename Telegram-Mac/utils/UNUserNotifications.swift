import Foundation
import UserNotifications
import SwiftSignalKit
import TelegramCore
import Postbox
import TGUIKit
import ApiCredentials
import AppKit
import NanogramRuntime



class UNUserNotifications : NSObject {
    
    enum AuthorizationStatus : Int {
        case notDetermined = 0
        case denied = 1
        case authorized = 2
        case provisional = 3
    }
    fileprivate let manager: SharedNotificationManager
    fileprivate let queue:Queue = Queue(name: "org.telegram.notifies")
    internal required init(manager: SharedNotificationManager) {
        self.manager = manager
        super.init()
        
        registerCategories()
    }
    
    fileprivate var bindings: SharedNotificationBindings {
        return manager.bindings
    }
    
    
    func registerCategories() {
       
    }
    static var _current:UNUserNotifications?
    static func initialize(manager: SharedNotificationManager) {
        if #available(macOS 10.14, *) {
            _current = UNUserNotificationsNew(manager: manager)
        } else {
            _current = UNUserNotificationsOld(manager: manager)
        }
    }
    static var current:UNUserNotifications? {
        return _current
    }
    
    static func recurrentAuthorizationStatus(_ context: AccountContext) -> Signal<AuthorizationStatus, NoError> {
        return context.window.keyWindowUpdater |> mapToSignal { _ in
            return (authorizationStatus |> then(.complete() |> suspendAwareDelay(1 * 60.0, queue: Queue.concurrentDefaultQueue()))) |> restart
        } |> distinctUntilChanged
    }
    
    static var authorizationStatus: Signal<AuthorizationStatus, NoError> {
        return Signal { subscriber in
            if #available(macOS 10.14, *) {
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    if let value = AuthorizationStatus(rawValue: settings.authorizationStatus.rawValue) {
                        subscriber.putNext(value)
                        subscriber.putCompletion()
                    }
                }
            } else {
                subscriber.putNext(.authorized)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }
    
    fileprivate func activateNotification(userInfo:[AnyHashable : Any], replyText: String? = nil) {
        if let id = userInfo["story.peer.id"] as? Int64, let namespace = userInfo["story.peer.namespace"] as? Int32, let accountId = userInfo["accountId"] as? Int64 {
            guard let account = manager.activeAccounts.accounts.first(where: { $0.0 == AccountRecordId(rawValue: accountId) })?.1 else {
                return
            }
            let peerId = PeerId(namespace: PeerId.Namespace._internalFromInt32Value(namespace), id: PeerId.Id._internalFromInt64Value(id))
            self.bindings.navigateToStory(account, peerId)
            return
        }
        if let messageId = getNotificationMessageId(userInfo: userInfo, for: "reply"), let accountId = userInfo["accountId"] as? Int64 {
            
            let accountId = AccountRecordId(rawValue: accountId)
            
            guard let account = manager.activeAccounts.accounts.first(where: {$0.0 == accountId})?.1 else {
                return
            }
            
            closeAllModals()
            
            if let text = replyText {
                if let sourceMessageId = getNotificationMessageId(userInfo: userInfo, for: "source") {
                    var replyToMessageId:MessageId?
                    if sourceMessageId.peerId.namespace != Namespaces.Peer.CloudUser {
                        replyToMessageId = sourceMessageId
                    }
                    _ = enqueueMessages(account: account, peerId: sourceMessageId.peerId, messages: [EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: Int64(messageId.id), replyToMessageId: replyToMessageId.flatMap { .init(messageId: $0, quote: nil, innerSubject: nil) }, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()

                } else {
                    var replyToMessageId:MessageId?
                    if messageId.peerId.namespace != Namespaces.Peer.CloudUser {
                        replyToMessageId = messageId
                    }
                    _ = enqueueMessages(account: account, peerId: messageId.peerId, messages: [EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: Int64(messageId.id), replyToMessageId: replyToMessageId.flatMap { .init(messageId: $0, quote: nil, innerSubject: nil) }, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
                }
            } else {
                let fromId = getNotificationMessageId(userInfo: userInfo, for: "source")
                let threadData: MessageHistoryThreadData?
                if let data = userInfo["thread_data"] as? Data {
                    threadData = CodableEntry(data: data).get(MessageHistoryThreadData.self)
                } else {
                    threadData = nil
                }
                let isThread = userInfo["is_thread"] as? Bool
                if let threadId = getNotificationMessageId(userInfo: userInfo, for: "thread"), isThread == true {
                    self.bindings.navigateToThread(account, threadId, fromId, threadData)
                } else {
                    self.bindings.navigateToChat(account, messageId.peerId)
                }
                
                manager.find(accountId)?.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            manager.find(nil)?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func add(_ notification: NSUserNotification) -> Void {
        
    }
    
    func clearNotifies(_ peerId:PeerId, maxId:MessageId) {
        
    }


    func clearNotifies(by msgIds: [MessageId]) {
       
    }
    
    func authorize(completion:@escaping(UNUserNotifications)->Void) {
        
    }

}


final class UNUserNotificationsOld : UNUserNotifications, NSUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: NSUserNotificationCenter, didDeliver notification: NSUserNotification) {
        
        let window: Window?
        if let accountId = notification.userInfo?["accountId"] as? Int64 {
            let accountId = AccountRecordId(rawValue: accountId)
            window = manager.find(accountId)?.window
        } else {
            window = manager.find(nil)?.window
        }
        guard let window = window else {
            return
        }
        if manager.requestUserAttention && !window.isKeyWindow {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if let soundName = notification.soundName {
            if soundName != "default" {
                appDelegate?.playSound(soundName)
                notification.soundName = nil
            }
        }
    }
    
    required init(manager: SharedNotificationManager) {
        super.init(manager: manager)
        NSUserNotificationCenter.default.delegate = self
    }
    
    

    @objc func userNotificationCenter(_ center: NSUserNotificationCenter, didDismissAlert notification: NSUserNotification) {
        if let userInfo = notification.userInfo, let timestamp = userInfo["timestamp"] as? Int32, let _ = userInfo["accountId"] as? Int64, let messageId = getNotificationMessageId(userInfo: userInfo, for: "reply") {
            
            bindings.applyMaxReadIndexInteractively(MessageIndex(id: messageId, timestamp: timestamp))
        }
    }
    
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        center.removeDeliveredNotification(notification)
    }
    override func authorize(completion:@escaping(UNUserNotifications)->Void) {
        completion(self)
    }
    
    override func clearNotifies(_ peerId:PeerId, maxId:MessageId) {
        queue.async {
            
           let deliveredNotifications = NSUserNotificationCenter.default.deliveredNotifications
                        
            for notification in deliveredNotifications {
                if let notificationMessageId = getNotificationMessageId(userInfo: notification.userInfo ?? [:], for: "reply") {
                                   
                    let timestamp = notification.userInfo?["timestamp"] as? Int32 ?? 0
                    
                    if notificationMessageId.peerId == peerId, notificationMessageId <= maxId {
                        NSUserNotificationCenter.default.removeDeliveredNotification(notification)
                    } else if timestamp == 0 || timestamp + 24 * 60 * 60 < Int32(Date().timeIntervalSince1970) {
                        NSUserNotificationCenter.default.removeDeliveredNotification(notification)
                    }
                }
            }
        }
    }


    override func clearNotifies(by msgIds: [MessageId]) {
        queue.async {
            let deliveredNotifications = NSUserNotificationCenter.default.deliveredNotifications
            
            for notification in deliveredNotifications {
                if let notificationMessageId = getNotificationMessageId(userInfo: notification.userInfo ?? [:], for: "reply") {
                    for msgId in msgIds {
                        if notificationMessageId == msgId {
                            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
                        }
                    }
                }
            }
        }
    }
    
    override func add(_ notification: NSUserNotification) -> Void {
        NSUserNotificationCenter.default.deliver(notification)
    }
}
    
@available(macOS 10.14, *)
final class UNUserNotificationsNew : UNUserNotifications, UNUserNotificationCenterDelegate {
    
    private var soundSettings: UNNotificationSetting? = nil
    required init(manager: SharedNotificationManager) {
        super.init(manager: manager)
        UNUserNotificationCenter.current().delegate = self
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {

        completionHandler([.alert, .sound])
    }
    
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    
        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier: // Notification was dismissed by user
            completionHandler()
        case UNNotificationDefaultActionIdentifier:
            activateNotification(userInfo: response.notification.request.content.userInfo)
            if manager.requestUserAttention {
                NSApp.requestUserAttention(.informationalRequest)
            }
            completionHandler()
         case UNNotification.replyCategory:
            if let textResponse = response as? UNTextInputNotificationResponse {
                let reply = textResponse.userText
                activateNotification(userInfo: response.notification.request.content.userInfo, replyText: reply)
                completionHandler()
            }
        default:
            completionHandler()
        }
    }
    
    override func registerCategories() {
        let replyAction = UNTextInputNotificationAction(identifier: "reply", title: strings().notificationReply, options: [], textInputButtonTitle: strings().notificationTitleReply, textInputPlaceholder: strings().notificationInputReply)
        
        
        let replyCategory = UNNotificationCategory(identifier: "reply", actions: [replyAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([replyCategory])
        
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            self?.soundSettings = settings.soundSetting
        }
    }
    override func add(_ notification: NSUserNotification) -> Void {
        let content = UNMutableNotificationContent()
        content.title = notification.title ?? ""
        content.body = notification.informativeText ?? ""
        content.subtitle = notification.subtitle ?? ""
        
        if notification.hasReplyButton {
            content.categoryIdentifier = UNNotification.replyCategory
        }
        
        let avatarPNG = notification.contentImage.flatMap { $0.nanogramPNGRepresentation }
        if let avatarPNG = avatarPNG, let attachment = UNNotificationAttachment.create(identifier: notification.identifier ?? "image", png: avatarPNG) {
            content.attachments = [attachment]
        }
        content.userInfo = notification.userInfo ?? [:]
        let soundSettings = self.soundSettings
        
        guard let containerUrl = ApiEnvironment.legacyContainerURL?.path else {
            return
        }
        
        if let soundName = notification.soundName {
            if soundName == "default" {
                content.sound = .default
            } else {
                if let soundSettings = soundSettings {
                    switch soundSettings {
                    case .enabled:
                        if soundName.hasPrefix(containerUrl) {
                            content.sound = nil
                            appDelegate?.playSound(soundName)
                        } else {
                            let name = soundName.nsstring.lastPathComponent.nsstring.deletingPathExtension
                            content.sound = .init(named: .init(name))
                        }
                    default:
                        break
                    }
                }
            }
        }
        
        var finalContent: UNNotificationContent = content
        if #available(macOS 12.0, *), let info = CommunicationNotificationInfo(userInfo: content.userInfo, avatarPNG: avatarPNG) {
            finalContent = CommunicationNotifications.apply(info, to: content)
        }

        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.identifier ?? "", content: finalContent, trigger: nil), withCompletionHandler: { error in
                        
           
        })
    }
    
    override func authorize(completion: @escaping (UNUserNotifications) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound], completionHandler: { [weak self] completed, error in
            if completed, let strongSelf = self {
                completion(strongSelf)
            }
        })
    }
    
    private var deliveredClearer: DeliveredNotificationClearer<MessageId> {
        return DeliveredNotificationClearer(center: UNUserNotificationCenter.current(), key: { userInfo in
            return getNotificationMessageId(userInfo: userInfo, for: "reply")
        })
    }

    override func clearNotifies(_ peerId:PeerId, maxId:MessageId) {
        let clearer = self.deliveredClearer
        queue.async {
            let now = Int32(Date().timeIntervalSince1970)
            clearer.remove(where: { notificationMessageId, userInfo in
                let timestamp = userInfo["timestamp"] as? Int32 ?? 0
                if notificationMessageId.peerId == peerId, notificationMessageId <= maxId {
                    return true
                }
                return timestamp == 0 || timestamp + 24 * 60 * 60 < now
            })
        }
    }


    override func clearNotifies(by msgIds: [MessageId]) {
        let clearer = self.deliveredClearer
        queue.async {
            clearer.remove(matching: Set(msgIds))
        }
    }
}







@available(macOS 10.14, *)
private extension UNNotificationAttachment {

    static func create(identifier: String, png: Data) -> UNNotificationAttachment? {
        guard let fileURL = NotificationAvatarStore.write(png, identifier: identifier) else {
            return nil
        }
        return try? UNNotificationAttachment(identifier: fileURL.lastPathComponent, url: fileURL, options: nil)
    }
}

private extension NSImage {
    var nanogramPNGRepresentation: Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}


@available(macOS 10.14, *)
private extension UNNotification {
    static let replyCategory: String = "reply"
}
