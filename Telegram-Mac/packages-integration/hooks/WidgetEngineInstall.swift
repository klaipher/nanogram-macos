import Foundation
import WidgetEngineXPC
import HTMLBubbles

func installWidgetEngineService() {
    let serviceName = MessageWidgetPolicy.engineServiceName(embedded: WidgetEngineXPC.embeddedServiceName(), fallback: MessageWidgetPolicy.engineServiceFallbackName)
    WidgetEngineXPC.install(serviceName: serviceName)
}
