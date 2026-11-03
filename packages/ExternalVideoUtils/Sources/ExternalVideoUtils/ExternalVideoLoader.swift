import Cocoa
import TelegramCore
import ObjcUtils
import Postbox
import SwiftSignalKit
import InAppVideoServices
import TGUIKit
import TelegramTheme

public let sharedVideoLoader:ExternalVideoLoader = {
    let shared = ExternalVideoLoader()
    return shared
}()


public final class ExternalVideo : Equatable {
    public let dimensions:NSSize
    public let quality:NSSize
    public let stream:String
    public let date: TimeInterval
    init(dimensions:NSSize, stream:String, quality:NSSize, date: TimeInterval) {
        self.dimensions = dimensions
        self.stream = stream
        self.quality = quality
        self.date = date
    }
}

public func ==(lhs:ExternalVideo, rhs:ExternalVideo) -> Bool {
    return lhs.stream == rhs.stream && lhs.date == rhs.date
}

public enum ExternalVideoStatus {
    case fetching
    case fail
    case loaded(ExternalVideo)
}

public class WrappedExternalVideoId : Hashable {
    public let id: String
    
    public init(_ id: String) {
        self.id = id
    }
    
    public static func ==(lhs: WrappedExternalVideoId, rhs: WrappedExternalVideoId) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}

private final class ExternalVideoStatusContext {
    public var status: ExternalVideoStatus?
    public let subscribers = Bag<(ExternalVideoStatus?) -> Void>()
}

private let youtubeName = "YouTube"
private let vimeoName = "Vimeo"

fileprivate let twitterIcon = TelegramThemeHooks.shared.image(.icons8CircledPlay48).precomposed()
fileprivate let youtubeIcon = TelegramThemeHooks.shared.image(.iconYouTubePlay).precomposed()
fileprivate let vimeoIcon = TelegramThemeHooks.shared.image(.iconVimeoPlay).precomposed()

public class ExternalVideoLoader {
    
    private let statusQueue = resourcesQueue
    private var statusContexts: [WrappedExternalVideoId: ExternalVideoStatusContext] = [:]
   
    private var dataContexts:[WrappedExternalVideoId: ExternalVideo] = [:]
    
    private var cancelTokensYT:[WrappedExternalVideoId: XCDYouTubeOperation] = [:]
    private var cancelTokensVimeo:[WrappedExternalVideoId: Any] = [:]
    
    public static func isPlayable(_ content:TelegramMediaWebpageLoadedContent) -> Bool {
        
        return (content.websiteName == youtubeName || content.websiteName == vimeoName) && content.image != nil
    }
    
    public static func playIcon(_ content:TelegramMediaWebpageLoadedContent) -> CGImage? {
        if let embedUrl = content.embedUrl {
            if embedUrl.contains("twitter.com/i/videos") && content.image != nil {
                return twitterIcon
            }
        }
        if content.websiteName == vimeoName  {
            return vimeoIcon
        } else if content.websiteName == youtubeName {
            return youtubeIcon
        }
        return nil
    }
    
    
    public func status(for content:TelegramMediaWebpageLoadedContent) -> Signal<ExternalVideoStatus?, Void> {
        return self.status(forKey: content.displayUrl)
    }
    
    var statusContextCount: Int {
        var count = 0
        self.statusQueue.sync {
            count = self.statusContexts.count
        }
        return count
    }
    
    var cachedVideoCount: Int {
        var count = 0
        self.statusQueue.sync {
            count = self.dataContexts.count
        }
        return count
    }
    
    func store(video: ExternalVideo, forKey key: String) {
        self.statusQueue.sync {
            self.storeVideo(video, for: WrappedExternalVideoId(key))
        }
    }
    
    private static let videoLifetime: TimeInterval = 30 * 60
    
    private func isFresh(_ video: ExternalVideo) -> Bool {
        return Date().timeIntervalSince1970 - ExternalVideoLoader.videoLifetime < video.date
    }
    
    private func storeVideo(_ video: ExternalVideo, for id: WrappedExternalVideoId) {
        self.dataContexts = self.dataContexts.filter { self.isFresh($0.value) }
        self.dataContexts[id] = video
    }
    
    private func freshVideo(for id: WrappedExternalVideoId) -> ExternalVideo? {
        guard let video = self.dataContexts[id] else {
            return nil
        }
        if self.isFresh(video) {
            return video
        }
        self.dataContexts.removeValue(forKey: id)
        return nil
    }
    
    private func removeStatusContextIfUnused(_ id: WrappedExternalVideoId) {
        guard let context = self.statusContexts[id], context.subscribers.isEmpty else {
            return
        }
        if self.cancelTokensYT[id] != nil || self.cancelTokensVimeo[id] != nil {
            return
        }
        self.statusContexts.removeValue(forKey: id)
    }
    
    func status(forKey key: String) -> Signal<ExternalVideoStatus?, Void> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.statusQueue.async {
                
                let statusContext: ExternalVideoStatusContext
                if let current = self.statusContexts[WrappedExternalVideoId(key)] {
                    statusContext = current
                } else {
                    statusContext = ExternalVideoStatusContext()
                    if let video = self.freshVideo(for: WrappedExternalVideoId(key)) {
                        statusContext.status = .loaded(video)
                    }
                    self.statusContexts[WrappedExternalVideoId(key)] = statusContext
                }
                
                let index = statusContext.subscribers.add({ status in
                    subscriber.putNext(status)
                })
                
                if let status = statusContext.status {
                    subscriber.putNext(status)
                }
                
                disposable.set(ActionDisposable {
                    self.statusQueue.async {
                        if let current = self.statusContexts[WrappedExternalVideoId(key)] {
                            current.subscribers.remove(index)
                        }
                        self.removeStatusContextIfUnused(WrappedExternalVideoId(key))
                    }
                })
            }
            
            return disposable
        }
        
    }
    
    public func fetch(for content:TelegramMediaWebpageLoadedContent) -> Signal<ExternalVideo?,Void> {
        if content.displayUrl.lowercased().contains(youtubeName.lowercased()) {
            return .single(nil) //fetchYoutubeContent(for: content.displayUrl)
        }
        if content.displayUrl.lowercased().contains(vimeoName.lowercased()) {
            return fetchVimeoContent(for: content.displayUrl)
        }
        return .fail(Void())
    }
    
    private func fetchYoutubeContent(for embed:String) -> Signal<ExternalVideo?,Void> {
        return Signal { subscriber in
            
            let disposable:MetaDisposable = MetaDisposable()
            
            self.statusQueue.async {
                if let video = self.freshVideo(for: WrappedExternalVideoId(embed)) {
                    subscriber.putNext(video)
                    subscriber.putCompletion()
                } else if let statusContext = self.statusContexts[WrappedExternalVideoId(embed)], statusContext.status != nil {
                    subscriber.putCompletion()
                } else if self.cancelTokensYT[WrappedExternalVideoId(embed)] == nil  {
                    
                    if let statusContext = self.statusContexts[WrappedExternalVideoId(embed)] {
                        statusContext.status = .fetching
                        
                        for subscriber in statusContext.subscribers.copyItems() {
                            subscriber(statusContext.status)
                        }
                    }
                    
                    self.cancelTokensYT[WrappedExternalVideoId(embed)] = XCDYouTubeClient.default().getVideoWithIdentifier(ObjcUtils.youtubeIdentifier(embed), completionHandler: { (video, error) in
                        
                        self.statusQueue.async {
                            var status:ExternalVideoStatus
                            var externalVideo:ExternalVideo?
                            if let video = video {
                                
                                var quality:NSSize? = nil
                                var stream:String? = nil
                                if let url = video.streamURLs[XCDYouTubeVideoQualityHTTPLiveStreaming] {
                                    quality = NSMakeSize(1280, 720)
                                    stream = url.absoluteString
                                } else if let url = video.streamURLs[22 as NSNumber] {
                                    quality = NSMakeSize(1280, 720)
                                    stream = url.absoluteString
                                } else if let url = video.streamURLs[18 as NSNumber] {
                                    quality = NSMakeSize(480, 360)
                                    stream = url.absoluteString
                                } else if let url = video.streamURLs[36 as NSNumber] {
                                    quality = NSMakeSize(320, 240)
                                    stream = url.absoluteString
                                }
                                if let quality = quality, let stream = stream {
                                    let video = ExternalVideo(dimensions: NSMakeSize(1280, 720), stream: stream, quality: quality, date: Date().timeIntervalSince1970)
                                    externalVideo = video
                                    self.storeVideo(video, for: WrappedExternalVideoId(embed))
                                    status = .loaded(video)
                                } else {
                                    status = .fail
                                }
                            } else {
                                status = .fail
                            }
                            
                            if self.statusContexts[WrappedExternalVideoId(embed)] == nil {
                                self.statusContexts[WrappedExternalVideoId(embed)] = ExternalVideoStatusContext()
                            }
                            
                            if let statusContext = self.statusContexts[WrappedExternalVideoId(embed)] {
                                statusContext.status = status
                                
                                for subscriber in statusContext.subscribers.copyItems() {
                                    subscriber(status)
                                }
                            }
                            
                            subscriber.putNext(externalVideo)
                            subscriber.putCompletion()
                        }
                        
                    })
                }
                disposable.set(ActionDisposable {
                    self.statusQueue.async {
                        if let operation = self.cancelTokensYT[WrappedExternalVideoId(embed)] {
                            operation.cancel()
                            self.cancelTokensYT.removeValue(forKey: WrappedExternalVideoId(embed))
                            
                            if let statusContext = self.statusContexts[WrappedExternalVideoId(embed)], let status = statusContext.status, case .fetching = status {
                                statusContext.status = nil
                                
                                for subscriber in statusContext.subscribers.copyItems() {
                                    subscriber(statusContext.status)
                                }
                            }
                        }
                        self.removeStatusContextIfUnused(WrappedExternalVideoId(embed))
                    }
                })
            }
            
            
            return disposable
        }
    }
    
    private func fetchVimeoContent(for embed:String) -> Signal<ExternalVideo?,Void> {
        return Signal { subscriber in
            
            let disposable:MetaDisposable = MetaDisposable()
            
            self.statusQueue.async {
                
                var canceled:Bool = false
                
                if let video = self.freshVideo(for: WrappedExternalVideoId(embed)) {
                    subscriber.putNext(video)
                    subscriber.putCompletion()
                } else if self.cancelTokensVimeo[WrappedExternalVideoId(embed)] == nil  {
                    
                    if let statusContext = self.statusContexts[WrappedExternalVideoId(embed)] {
                        statusContext.status = .fetching
                        
                        for subscriber in statusContext.subscribers.copyItems() {
                            subscriber(statusContext.status)
                        }
                    }
                    
                    self.cancelTokensVimeo[WrappedExternalVideoId(embed)] = 1
                    
                    YTVimeoExtractor.shared().fetchVideo(withVimeoURL: embed, withReferer: nil, completionHandler: { (video, error) in
                        if !canceled {
                            self.statusQueue.async {
                                var status:ExternalVideoStatus
                                var externalVideo:ExternalVideo?
                                if let video = video {
                                    
                                    let quality:NSSize = NSMakeSize(1280, 720)
                                    let stream:String? = video.highestQualityStreamURL()?.absoluteString
                                    if let stream = stream {
                                        let video = ExternalVideo(dimensions: NSMakeSize(1280, 720), stream: stream, quality: quality, date: Date().timeIntervalSince1970)
                                        externalVideo = video
                                        self.storeVideo(video, for: WrappedExternalVideoId(embed))
                                        status = .loaded(video)
                                    } else {
                                        status = .fail
                                    }
                                   
                                } else {
                                    status = .fail
                                }
                                
                                if let statusContext = self.statusContexts[WrappedExternalVideoId(embed)] {
                                    statusContext.status = status
                                    
                                    for subscriber in statusContext.subscribers.copyItems() {
                                        subscriber(status)
                                    }
                                }
                                
                                subscriber.putNext(externalVideo)
                                subscriber.putCompletion()
                            }

                        }
                    })

                }
                disposable.set(ActionDisposable {
                    self.statusQueue.async {
                        if let _ = self.cancelTokensVimeo[WrappedExternalVideoId(embed)] {
                            self.cancelTokensVimeo.removeValue(forKey: WrappedExternalVideoId(embed))
                            canceled = true
                            if let statusContext = self.statusContexts[WrappedExternalVideoId(embed)], let status = statusContext.status, case .fetching = status {
                                statusContext.status = nil
                                
                                for subscriber in statusContext.subscribers.copyItems() {
                                    subscriber(statusContext.status)
                                }
                            }
                        }
                        self.removeStatusContextIfUnused(WrappedExternalVideoId(embed))
                    }
                })
            }
            
            
            return disposable
        }

    }
}


