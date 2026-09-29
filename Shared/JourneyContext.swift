import Foundation
import BusioKit

/// Libellés d'un itinéraire (lignes, arrêts, destination) pour les alertes et la Live Activity.
struct JourneyContext: Sendable {
    var title: String
    var destinationName: String
    var styles: [LineStyle]
    var network: Network?

    init(title: String, destinationName: String, styles: [LineStyle], network: Network?) {
        self.title = title
        self.destinationName = destinationName
        self.styles = styles
        self.network = network
    }

    init(snapshot: TripSnapshot, network: Network?) {
        self.init(title: snapshot.title, destinationName: snapshot.destinationName, styles: snapshot.lines, network: network)
    }

    init(followed: FollowedJourney, network: Network?) {
        self.init(title: followed.title, destinationName: followed.request.to.name,
                  styles: network?.lines.map(LineStyle.init) ?? [], network: network)
    }

    func style(_ lineID: String) -> LineStyle? { styles.first { $0.id == lineID } }
    func badge(_ lineID: String) -> String { style(lineID)?.badge ?? "" }
    func stopName(_ stopID: String) -> String {
        network?.stop(stopID)?.name ?? network?.area(containingStop: stopID)?.name ?? "l'arrêt"
    }

    // MARK: Correspondance menacée

    func issueTitle(_ issue: JourneyIssue, journey: PlannedJourney) -> String {
        switch issue.kind {
        case .tightTransfer: "Correspondance juste"
        case .missedTransfer: "Correspondance ratée"
        case .cancelled: journey.rides.indices.contains(issue.rideIndex) ? "Bus \(badge(journey.rides[issue.rideIndex].lineID)) supprimé" : "Bus supprimé"
        }
    }

    /// Détail pour la notification et l'app.
    func issueMessage(_ issue: JourneyIssue, journey: PlannedJourney, planB: PlannedJourney?) -> String {
        let rides = journey.rides
        guard rides.indices.contains(issue.rideIndex) else { return "" }
        let threatened = rides[issue.rideIndex]
        var text: String
        switch issue.kind {
        case .tightTransfer, .missedTransfer:
            let previous = rides[issue.rideIndex - 1]
            let delay = previous.delay.map { $0 >= 60 ? " (+\(Int(($0 / 60).rounded())) min)" : "" } ?? ""
            text = "Le \(badge(previous.lineID)) arrive à \(stopName(previous.alight.stopID)) à \(TimeText.clock(previous.arrival))\(delay), "
                + "le \(badge(threatened.lineID)) part à \(TimeText.clock(threatened.departure))"
            if issue.kind == .tightTransfer, let slack = issue.slack {
                text += " : \(slack < 30 ? "quelques secondes" : "moins d'une minute") pour changer."
            } else {
                text += "."
            }
        case .cancelled:
            let scheduled = threatened.board.scheduled ?? threatened.departure
            text = "Le \(badge(threatened.lineID)) de \(TimeText.clock(scheduled)) à \(stopName(threatened.board.stopID)) est supprimé."
        }
        if let planB, let summary = planSummary(planB, from: issue.rideIndex) {
            text += issue.kind == .tightTransfer ? " Si tu le rates : \(summary)." : " Plan B : \(summary) (au lieu de \(TimeText.clock(journey.arrival)))."
        } else if issue.isBlocking {
            text += " Aucun autre bus trouvé pour l'instant : ouvre Busio."
        }
        return text
    }

    /// Une ligne pour la Live Activity.
    func issueShort(_ issue: JourneyIssue, journey: PlannedJourney, planB: PlannedJourney?) -> String {
        let plan = planB.flatMap { planHeadline($0, from: issue.rideIndex) }
        switch issue.kind {
        case .tightTransfer:
            return "Correspondance juste" + (plan.map { " · sinon \($0)" } ?? "")
        case .missedTransfer:
            return "Correspondance ratée" + (plan.map { " · plan B \($0)" } ?? "")
        case .cancelled:
            return issueTitle(issue, journey: journey) + (plan.map { " · plan B \($0)" } ?? "")
        }
    }

    /// « 10 à 18:55 depuis Gare SNCF, arrivée 19:37 »
    func planSummary(_ plan: PlannedJourney, from rideIndex: Int) -> String? {
        let rides = plan.rides
        guard rides.indices.contains(rideIndex) else { return nil }
        let ride = rides[rideIndex]
        return "\(badge(ride.lineID)) à \(TimeText.clock(ride.departure)) depuis \(stopName(ride.board.stopID)), arrivée \(TimeText.clock(plan.arrival))"
    }

    /// « 10 à 18:55 »
    func planHeadline(_ plan: PlannedJourney, from rideIndex: Int) -> String? {
        let rides = plan.rides
        guard rides.indices.contains(rideIndex) else { return nil }
        return "\(badge(rides[rideIndex].lineID)) à \(TimeText.clock(rides[rideIndex].departure))"
    }
}
