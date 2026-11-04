import Foundation
import MapKit
import SwiftSignalKit
import TelegramCore
import Postbox
import HardenedMedia

func mapKitVenueResults(peerId: PeerId, location: CLLocation, query: String) -> Signal<ChatContextResultCollection?, NoError> {
    return Signal { subscriber in
        let center = location.coordinate
        let search: MKLocalSearch
        if !query.isEmpty {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 2000.0, longitudinalMeters: 2000.0)
            request.resultTypes = [.pointOfInterest, .address]
            search = MKLocalSearch(request: request)
        } else {
            search = MKLocalSearch(request: MKLocalPointsOfInterestRequest(center: center, radius: 1000.0))
        }
        search.start(completionHandler: { response, _ in
            guard let response else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return
            }
            var results: [ChatContextResult] = []
            for (index, item) in response.mapItems.enumerated() {
                guard let title = item.name, !title.isEmpty else {
                    continue
                }
                let placemark = item.placemark
                let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let address = [street, placemark.locality ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                let media = TelegramMediaMap(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude, heading: nil, accuracyRadius: nil, venue: MapVenue(title: title, address: address, provider: nil, id: nil, type: nil), liveBroadcastingTimeout: nil, liveProximityNotificationRadius: nil)
                results.append(.externalReference(ChatContextResult.ExternalReference(queryId: 0, id: "mapkit-\(index)", type: "venue", title: title, description: address, url: nil, content: nil, thumbnail: nil, message: .mapLocation(media: media, replyMarkup: nil))))
            }
            subscriber.putNext(ChatContextResultCollection(botId: peerId, peerId: peerId, query: query, geoPoint: nil, queryId: 0, nextOffset: nil, presentation: .list, switchPeer: nil, webView: nil, results: results, cacheTimeout: 0))
            subscriber.putCompletion()
        })
        return ActionDisposable {
            search.cancel()
        }
    }
}
