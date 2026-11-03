import Foundation
import TextRecognizing
import SwiftSignalKit
import TelegramCore
import Postbox
import Translate
import TGUIKit
import Localization
import TelegramTheme
import TelegramContext
import TelegramUtils
import ChatModeTypes
import ChatHistoryModel
import GeneralRows
import LocalAnimations
import TelegramMediaUtils
import TelegramMedia
import AvatarUI
import MessageUtils
import InstantPageUI
import SecureIdUtils
import ColorPalette
import InAppSettings
import FoundationUtils
import ObjcUtils

public final class GalleryRecognition {
    static let dwell: Double = 1.0
    private static var cleanedPostboxes = Set<String>()

    private let item: MGalleryPhotoItem
    private let disposable = MetaDisposable()
    private let magnifyDisposable = MetaDisposable()
    private let subjectDisposable = MetaDisposable()
    private let loadedDisposable = MetaDisposable()
    private var isFullImageLoaded: Bool = false

    public var openLink: ((String) -> Void)?

    public let view: NSView

    public init?(_ item: MGalleryItem) {
        if let postbox = (item as? MGalleryPhotoItem)?.context.account.postbox {
            GalleryRecognition.removeLegacyStore(postbox)
        }
        guard #available(macOS 13.0, *), LiveTextAnalyzer.isSupported, let item = item as? MGalleryPhotoItem else {
            return nil
        }
        if let message = item.entry.message, message.isCopyProtected() {
            return nil
        }
        self.item = item
        let liveTextView = LiveTextView(frame: .zero)
        liveTextView.openLinkMenuTitle = strings().chatMessageOpenLink
        self.view = liveTextView

        let fullImageLoaded = item.path.get() |> take(1) |> map { _ in Void() }
        let states: Signal<LiveTextSchedule.State<CGImage>, NoError> = combineLatest(item.image.get(), item.magnify.get(), item.appearValue, fullImageLoaded) |> map { image, magnify, visible, _ in
            var cgImage: CGImage?
            if case let .image(image, _) = image.value {
                cgImage = image?._cgImage
            }
            return LiveTextSchedule.State(image: cgImage, isEligible: magnify == 1 && visible)
        }
        let analysis = LiveTextSchedule.analysis(states: states, dwell: GalleryRecognition.dwell, queue: .concurrentDefaultQueue(), analyze: { image in
            return LiveTextAnalyzer.shared.analyze(image)
        }) |> deliverOnMainQueue

        disposable.set(analysis.start(next: { [weak liveTextView] result in
            liveTextView?.set(result)
        }))

        magnifyDisposable.set((item.magnify.get() |> deliverOnMainQueue).start(next: { [weak liveTextView] magnify in
            liveTextView?.isActive = magnify == 1
        }))

        loadedDisposable.set((fullImageLoaded |> deliverOnMainQueue).start(next: { [weak self] in
            self?.isFullImageLoaded = true
        }))

        liveTextView.openCode = { [weak self] code in
            self?.open(code)
        }
    }

    deinit {
        disposable.dispose()
        magnifyDisposable.dispose()
        subjectDisposable.dispose()
        loadedDisposable.dispose()
    }

    private static func removeLegacyStore(_ postbox: Postbox) {
        let basePath = postbox.mediaBox.basePath
        guard !cleanedPostboxes.contains(basePath) else {
            return
        }
        cleanedPostboxes.insert(basePath)
        Queue.concurrentBackgroundQueue().async {
            _ = LiveTextLegacyStore.removeFiles(mediaBoxBasePath: basePath)
        }
        let key = applicationSpecificPreferencesKey(LiveTextLegacyStore.preferencesKey)
        _ = postbox.transaction { transaction -> Void in
            if transaction.getPreferencesEntry(key: key) != nil {
                transaction.updatePreferencesEntry(key: key, { _ in nil })
            }
        }.start()
    }

    @available(macOS 13.0, *)
    private var liveTextView: LiveTextView {
        return self.view as! LiveTextView
    }

    @available(macOS 13.0, *)
    private func open(_ code: LiveTextCode) {
        if let link = code.link {
            openLink?(link)
        } else {
            copy(code.payload)
        }
    }

    private func copy(_ text: String) {
        copyToClipboard(text)
        if let window = view.window as? Window {
            showModalText(for: window, text: strings().contextAlertCopied)
        }
    }

    public func openCode(atWindow point: NSPoint) -> Bool {
        guard #available(macOS 13.0, *), let code = liveTextView.code(atWindow: point) else {
            return false
        }
        open(code)
        return true
    }

    public func codeMenu(atWindow point: NSPoint) -> ContextMenu? {
        guard #available(macOS 13.0, *), let code = liveTextView.code(atWindow: point) else {
            return nil
        }
        let menu = ContextMenu(presentation: .current(darkPalette), betterInside: true)
        if let link = code.link {
            menu.addItem(ContextMenuItem(strings().chatMessageOpenLink, handler: { [weak self] in
                self?.openLink?(link)
            }, itemImage: MenuAnimation.menu_open_with.value))
            menu.addItem(ContextMenuItem(strings().textContextCopyLink, handler: { [weak self] in
                self?.copy(link)
            }, itemImage: MenuAnimation.menu_copy_link.value))
        } else {
            menu.addItem(ContextMenuItem(strings().contextCopy, handler: { [weak self] in
                self?.copy(code.payload)
            }, itemImage: MenuAnimation.menu_copy.value))
        }
        return menu
    }

    public var canLiftSubject: Bool {
        if #available(macOS 14.0, *) {
            return isFullImageLoaded
        } else {
            return false
        }
    }
    
    @available(macOS 14.0, *)
    private func liftSubject(at windowPoint: NSPoint?, completion: @escaping (TextRecognizing.Subject) -> Void) {
        let point = windowPoint.flatMap { liveTextView.normalizedPoint(fromWindow: $0) }
        let signal = item.image.get()
        |> take(1)
        |> mapToSignal { value -> Signal<TextRecognizing.Subject?, NoError> in
            switch value.value {
            case let .image(image, _):
                if let image = image?._cgImage {
                    return TextRecognizing.liftSubject(image, at: point)
                }
                return .single(nil)
            default:
                return .single(nil)
            }
        }
        |> deliverOnMainQueue
        
        subjectDisposable.set(signal.start(next: { [weak self] subject in
            guard let self else {
                return
            }
            if let subject {
                self.liveTextView.showLiftedSubject(subject.image, rect: subject.rect, completion: {
                    completion(subject)
                })
            } else if let window = self.view.window as? Window {
                showModalText(for: window, text: strings().gallerySubjectNotFound)
            }
        }))
    }
    
    public func copySubject(at windowPoint: NSPoint?) {
        guard #available(macOS 14.0, *) else {
            return
        }
        liftSubject(at: windowPoint, completion: { [weak self] subject in
            let representation = NSBitmapImageRep(cgImage: subject.image)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            if let tiff = representation.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            if let window = self?.view.window as? Window {
                showModalText(for: window, text: strings().contextAlertCopied)
            }
        })
    }
    
    public func sendSubjectAsSticker(at windowPoint: NSPoint?, send: @escaping (String) -> Void) {
        guard #available(macOS 14.0, *) else {
            return
        }
        liftSubject(at: windowPoint, completion: { subject in
            let signal: Signal<String?, NoError> = Signal { subscriber in
                subscriber.putNext(GalleryRecognition.writeSticker(subject))
                subscriber.putCompletion()
                return EmptyDisposable
            }
            |> runOn(.concurrentDefaultQueue())
            |> deliverOnMainQueue
            
            _ = signal.start(next: { path in
                if let path {
                    send(path)
                }
            })
        })
    }
    
    @available(macOS 14.0, *)
    private static func writeSticker(_ subject: TextRecognizing.Subject) -> String? {
        guard let data = subject.stickerData() else {
            return nil
        }
        let path = NSTemporaryDirectory() + "subject_sticker_\(arc4random64()).webp"
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return nil
        }
        return path
    }
    public var transcript: String? {
        guard #available(macOS 13.0, *) else {
            return nil
        }
        let text = liveTextView.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func translationSource(doNotTranslate: Set<String>) -> (text: String, fromLang: String?)? {
        guard let text = self.transcript else {
            return nil
        }
        let fromLang = Translate.detectLanguage(for: text)
        if let fromLang = fromLang, doNotTranslate.contains(fromLang) {
            return nil
        }
        return (text: text, fromLang: fromLang)
    }

    public var hasRecognition: Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return liveTextView.isActive && liveTextView.hasContent
    }

    public var hasSelectedText: Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return liveTextView.hasSelectedText
    }

    public func cancelSelection() {
        if #available(macOS 13.0, *) {
            liveTextView.resetSelection()
        }
    }

    public func copySelectedText() -> Bool {
        guard let text = self.selectedText else {
            return false
        }
        copyToClipboard(text)
        return true
    }

    public var selectedText: String? {
        guard #available(macOS 13.0, *) else {
            return nil
        }
        return liveTextView.selectedText
    }
}
