import Testing

@testable import NotifyCore

@Suite struct SpaceRouteTests {
    // The layout of the Mac this was written on: a built-in display with
    // eight Spaces and an external one with three, each showing its own.
    let builtIn = SpaceTopology.Display(
        identifier: "37D8", spaces: [4, 15, 6, 5, 105, 8, 14, 16], current: 6)
    let external = SpaceTopology.Display(identifier: "A756", spaces: [1773, 127, 10], current: 10)
    var topology: SpaceTopology { SpaceTopology(displays: [builtIn, external]) }

    @Test func aSpaceOnShowNeedsNoTravel() {
        #expect(SpaceRoute.to(6, in: topology) == .showing)
        #expect(SpaceRoute.to(10, in: topology) == .showing)
        #expect(topology.visibleSpaces == [6, 10])
        #expect(topology.shows(anyOf: [10]))
        #expect(!topology.shows(anyOf: [8, 1773]))
    }

    @Test func travelGoesTheShortWayOnTheDisplayThatHasTheSpace() {
        #expect(
            SpaceRoute.to(8, in: topology)
                == .hop(SpaceHop(display: "37D8", direction: .right, steps: 3, next: 5)))
        #expect(
            SpaceRoute.to(4, in: topology)
                == .hop(SpaceHop(display: "37D8", direction: .left, steps: 2, next: 15)))
        #expect(
            SpaceRoute.to(1773, in: topology)
                == .hop(SpaceHop(display: "A756", direction: .left, steps: 2, next: 127)))
    }

    @Test func aSpaceNoDisplayHasIsUnreachable() {
        #expect(SpaceRoute.to(999, in: topology) == .unreachable)
    }

    @Test func aDisplayWhoseCurrentSpaceIsUnknownIsUnreachable() {
        let blind = SpaceTopology(displays: [
            SpaceTopology.Display(identifier: "x", spaces: [1, 2], current: nil)
        ])
        #expect(SpaceRoute.to(2, in: blind) == .unreachable)
    }

    @Test func travelIsBounded() {
        let long = SpaceTopology(displays: [
            SpaceTopology.Display(
                identifier: "x", spaces: Array(1...UInt64(SpaceRoute.maxSteps + 2)), current: 1)
        ])
        #expect(SpaceRoute.to(UInt64(SpaceRoute.maxSteps + 1), in: long) != .unreachable)
        #expect(SpaceRoute.to(UInt64(SpaceRoute.maxSteps + 2), in: long) == .unreachable)
    }
}
