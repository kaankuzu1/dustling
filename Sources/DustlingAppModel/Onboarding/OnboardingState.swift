import Foundation
import Observation

/// The four steps of the onboarding flow, in order (SCREENS-final §1).
public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, fullDiskAccess, permissions, ready

    public var id: Self { self }
    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
}

/// The onboarding window's current step, which steps were actually completed, and the persisted flag
/// that keeps the onboarding from opening again at launch.
@MainActor @Observable
public final class OnboardingState {
    public static let completedKey = "onboardingCompleted"

    public var step: OnboardingStep = .welcome
    /// True once the user finished, skipped or closed the onboarding. Stored in UserDefaults.
    public private(set) var isCompleted: Bool
    /// Steps the user really completed in this session. A skipped step is never in here.
    public private(set) var completedSteps: Set<OnboardingStep> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var didHandleLaunch = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCompleted = defaults.bool(forKey: Self.completedKey)
    }

    /// Records that `step` was completed (its forward button was used, not "Skip for now").
    public func complete(_ step: OnboardingStep) {
        completedSteps.insert(step)
    }

    /// Whether the step list shows `step` as done. The Full Disk Access step is done exactly when
    /// access is on, however it was granted; the others when they were completed, never when skipped.
    public func isDone(_ step: OnboardingStep, fullDiskAccessGranted: Bool) -> Bool {
        step == .fullDiskAccess ? fullDiskAccessGranted : completedSteps.contains(step)
    }

    /// Finishing, skipping or closing the onboarding: it won't open again at launch. With Full Disk
    /// Access still off, Dustling then runs in limited mode and Home says so.
    public func markCompleted() {
        guard !isCompleted else { return }
        isCompleted = true
        defaults.set(true, forKey: Self.completedKey)
    }

    /// The window was closed some way, including its close button. That counts as done (limited mode
    /// if access is off), exactly like "Skip for now".
    public func windowClosed() {
        markCompleted()
    }

    /// True once per launch, and only while the onboarding was never completed.
    public func takeLaunchRequest() -> Bool {
        guard !didHandleLaunch else { return false }
        didHandleLaunch = true
        return !isCompleted
    }
}
