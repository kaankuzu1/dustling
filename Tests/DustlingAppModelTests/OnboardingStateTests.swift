import Foundation
import Testing
@testable import DustlingAppModel

@MainActor
struct OnboardingStateTests {
    /// A throwaway defaults domain per test, removed when the tests finish.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        body(ScratchDefaults.make("dustling-onboarding"))
    }

    @Test func onlyCompletedStepsAreDone() {
        withDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            state.complete(.welcome)
            // Full Disk Access skipped, helper step skipped too.
            #expect(state.isDone(.welcome, fullDiskAccessGranted: false))
            #expect(!state.isDone(.fullDiskAccess, fullDiskAccessGranted: false))
            #expect(!state.isDone(.permissions, fullDiskAccessGranted: false))
            #expect(!state.isDone(.ready, fullDiskAccessGranted: false))
            state.complete(.permissions)
            #expect(state.isDone(.permissions, fullDiskAccessGranted: false))
        }
    }

    @Test func fullDiskAccessStepIsDoneExactlyWhenAccessIsOn() {
        withDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            #expect(state.isDone(.fullDiskAccess, fullDiskAccessGranted: true))
            state.complete(.fullDiskAccess)
            // Access was lost again: the step is no longer done.
            #expect(!state.isDone(.fullDiskAccess, fullDiskAccessGranted: false))
        }
    }

    @Test func closingTheWindowCountsAsDoneAndPersists() {
        withDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            #expect(!state.isCompleted)
            state.windowClosed()
            #expect(state.isCompleted)
            #expect(defaults.bool(forKey: OnboardingState.completedKey))
            #expect(!OnboardingState(defaults: defaults).takeLaunchRequest())
        }
    }

    @Test func launchRequestIsOncePerLaunchWhileNotCompleted() {
        withDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            #expect(state.takeLaunchRequest())
            #expect(!state.takeLaunchRequest())
        }
    }
}
