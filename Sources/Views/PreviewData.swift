#if DEBUG
import SwiftUI
import SwiftData
import CoreLocation

/// Sample data for Xcode previews.
///
/// `PreviewData.container` is an in-memory SwiftData store seeded with a small, realistic graph:
/// a few people (located + unlocated, with notes and studies), a worked territory with doors and
/// do-not-calls, service plans, sessions, chat history, and today's breadcrumb. Previews attach it
/// with `.modelContainer(PreviewData.container)` and pull specific objects through the typed
/// accessors below (`PreviewData.person`, `.territory`, `.plan`, …).
///
/// Everything is `@MainActor` because SwiftData's `mainContext` is main-actor isolated; previews
/// run on the main actor, so this is free to use from a `#Preview` body.
@MainActor
enum PreviewData {

    /// The shared in-memory container, built once and reused across previews in a run.
    static let container: ModelContainer = {
        let container = AppModelContainer.make(inMemory: true)
        seed(container.mainContext)
        return container
    }()

    static var context: ModelContext { container.mainContext }

    // MARK: Typed accessors (fetch a deterministic sample by name)

    /// A located person who is being studied, with notes and an upcoming visit — the richest sample.
    static var person: Person { firstPerson(named: "Maria Alvarez") }
    /// A brand-new located contact with no study yet.
    static var newPerson: Person { firstPerson(named: "John Becker") }
    /// A person with no location set (exercises the "no coordinate" paths).
    static var unlocatedPerson: Person { firstPerson(named: "Sam Whitfield") }

    static var people: [Person] {
        (try? context.fetch(FetchDescriptor<Person>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// A worked territory with doors + do-not-calls and a center.
    static var territory: Territory {
        (try? context.fetch(FetchDescriptor<Territory>())).flatMap(\.first) ?? {
            let t = Territory(name: "Oak Street", latitude: 37.7749, longitude: -122.4194)
            context.insert(t)
            return t
        }()
    }

    /// An upcoming, weekly-recurring service plan.
    static var plan: ServicePlan {
        (try? context.fetch(FetchDescriptor<ServicePlan>())).flatMap(\.first) ?? {
            let p = ServicePlan(place: "Library steps", partner: "Daniel")
            context.insert(p)
            return p
        }()
    }

    /// A door (not-at-home) on the sample territory.
    static var door: NotAtHome { territory.doors.first ?? NotAtHome(address: "12 Oak St") }

    /// A completed service session.
    static var session: ServiceSession {
        (try? context.fetch(FetchDescriptor<ServiceSession>())).flatMap(\.first) ?? ServiceSession()
    }

    /// San Francisco, a convenient default coordinate for map previews.
    static let sampleCoordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    // MARK: Seeding

    private static func firstPerson(named name: String) -> Person {
        let descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.name == name })
        if let found = try? context.fetch(descriptor).first { return found }
        let p = Person(name: name)
        context.insert(p)
        return p
    }

    private static func seed(_ ctx: ModelContext) {
        // — People —————————————————————————————————————————————————————————————
        let maria = Person(name: "Maria Alvarez", addressText: "118 Elm Ave", interest: .studying,
                           createdAt: .now.addingTimeInterval(-86_400 * 9))
        maria.latitude = 37.7765; maria.longitude = -122.4230
        maria.headline = "Studying ‘Enjoy Life Forever!’, loves the resurrection hope"
        maria.nextVisitDate = .now.addingTimeInterval(86_400 * 2)
        maria.studyPublication = "Enjoy Life Forever!"
        maria.studyLesson = "7"
        ctx.insert(maria)
        ctx.insert(JournalEntry(date: .now.addingTimeInterval(-86_400 * 9),
                                text: "First conversation at the door — asked about why there's suffering.",
                                topic: "Suffering", scripture: "Revelation 21:4", person: maria))
        ctx.insert(JournalEntry(date: .now.addingTimeInterval(-86_400 * 2),
                                text: "Started lesson 7. Bringing the next brochure on resurrection.",
                                topic: "Resurrection", scripture: "John 5:28, 29", person: maria))

        let john = Person(name: "John Becker", addressText: "44 Pine St", interest: .new,
                          createdAt: .now.addingTimeInterval(-86_400 * 3))
        john.latitude = 37.7720; john.longitude = -122.4150
        john.headline = "Took a tract, busy with work — try evenings"
        ctx.insert(john)
        ctx.insert(JournalEntry(text: "Brief chat, accepted a tract. Said evenings are better.",
                                person: john))

        let sam = Person(name: "Sam Whitfield", interest: .paused,
                         createdAt: .now.addingTimeInterval(-86_400 * 20))
        sam.headline = "Asked us to come back after the holidays"
        ctx.insert(sam)

        // — Territory with doors + do-not-calls ——————————————————————————————
        let oak = Territory(name: "Oak Street", latitude: 37.7749, longitude: -122.4194,
                            createdAt: .now.addingTimeInterval(-86_400 * 14))
        oak.lastWorkedAt = .now.addingTimeInterval(-86_400 * 1)
        oak.dueDate = .now.addingTimeInterval(86_400 * 21)
        ctx.insert(oak)
        for (i, addr) in ["12 Oak St", "18 Oak St", "27 Oak St"].enumerated() {
            let door = NotAtHome(address: addr,
                                 latitude: 37.7749 + Double(i) * 0.0006,
                                 longitude: -122.4194 + Double(i) * 0.0004,
                                 createdAt: .now.addingTimeInterval(-86_400 * Double(7 - i)))
            door.territory = oak
            ctx.insert(door)
        }
        let dnc = DoNotCall(address: "5 Oak St", latitude: 37.7742, longitude: -122.4188)
        dnc.territory = oak
        ctx.insert(dnc)

        // — Congregation boundary —————————————————————————————————————————————
        let boundary = CongregationBoundary()
        boundary.setBoundary([
            CLLocationCoordinate2D(latitude: 37.770, longitude: -122.425),
            CLLocationCoordinate2D(latitude: 37.780, longitude: -122.425),
            CLLocationCoordinate2D(latitude: 37.780, longitude: -122.410),
            CLLocationCoordinate2D(latitude: 37.770, longitude: -122.410),
        ])
        ctx.insert(boundary)

        // — Service plans —————————————————————————————————————————————————————
        let weekly = ServicePlan(date: .now.addingTimeInterval(86_400 * 1), durationMinutes: 120,
                                 place: "Library steps", partner: "Daniel",
                                 note: "Cart work, then door-to-door on Oak.", recurrence: "weekly")
        ctx.insert(weekly)
        ctx.insert(ServicePlan(date: .now.addingTimeInterval(86_400 * 5), durationMinutes: 90,
                               place: "Kingdom Hall", partner: "Ruth"))

        // — Service sessions ——————————————————————————————————————————————————
        let done = ServiceSession(startAt: .now.addingTimeInterval(-86_400 - 7200), territory: oak,
                                  notes: "Apartment complex on Oak.")
        done.endAt = .now.addingTimeInterval(-86_400 - 1800)
        ctx.insert(done)

        // — Chat history (general notebook) ———————————————————————————————————
        ctx.insert(ChatMessage(date: .now.addingTimeInterval(-300),
                               text: "Add a visit with Maria — started lesson 7 today.", isFromUser: true))
        ctx.insert(ChatMessage(date: .now.addingTimeInterval(-280),
                               text: "Done — I noted lesson 7 for **Maria Alvarez** and set a reminder for Thursday.",
                               isFromUser: false, cardPersonID: maria.id))

        // — Today's breadcrumb ————————————————————————————————————————————————
        for i in 0..<5 {
            ctx.insert(VisitLog(coordinate: CLLocationCoordinate2D(latitude: 37.7749 + Double(i) * 0.0008,
                                                                   longitude: -122.4194 + Double(i) * 0.0006),
                                timestamp: .now.addingTimeInterval(-Double(5 - i) * 1200),
                                context: i == 0 ? "return_visit" : "not_at_home"))
        }

        try? ctx.save()
    }
}
#endif
