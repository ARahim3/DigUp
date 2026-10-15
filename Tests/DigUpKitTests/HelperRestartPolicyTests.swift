import Testing
@testable import DigUpKit

@Suite struct HelperRestartPolicyTests {
    @Test func resumeWhileStopIsPendingRestartsAfterExit() {
        var policy = HelperRestartPolicy()
        policy.requestStop()
        policy.requestStart()

        let shouldRestart = policy.helperExited()
        let shouldNotRestartAgain = policy.helperExited()

        #expect(shouldRestart)
        #expect(!shouldNotRestartAgain)
    }

    @Test func pauseWithoutResumeDoesNotRestart() {
        var policy = HelperRestartPolicy()
        policy.requestStop()

        let shouldNotRestart = policy.helperExited()

        #expect(!shouldNotRestart)
    }

    @Test func startWithNoPendingStopDoesNotScheduleAnExtraRun() {
        var policy = HelperRestartPolicy()
        policy.requestStart()

        let shouldNotRestart = policy.helperExited()

        #expect(!shouldNotRestart)
    }
}
