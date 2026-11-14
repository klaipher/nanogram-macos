import Foundation
import NanogramDebug
import NanogramLogExport

public enum NanogramExperimentEnergy {
    nonisolated(unsafe) private static var observations: [NanogramDebugObservation] = []

    /// Starts each switch's energy window again whenever the switch changes.
    public static func install(settings: NanogramDebugSettings = .shared, ledger: NanogramEnergyLedger = .shared) {
        observations.forEach { $0.cancel() }
        observations = settings.options.map { option in
            let id = option.id
            return settings.observe(id) { _ in
                ledger.reset(id)
            }
        }
    }

    public static func reportText(settings: NanogramDebugSettings = .shared, ledger: NanogramEnergyLedger = .shared, power: NanogramPowerContext = .current()) -> String {
        let experiments = settings.options.map { option -> (id: String, title: String, value: String) in
            switch option.kind {
            case .toggle:
                return (option.id, option.title, settings.bool(option.id) ? "on" : "off")
            case .choice:
                return (option.id, option.title, settings.choice(option.id) ?? "default")
            }
        }
        return ledger.report(experiments: experiments, power: power)
    }
}
