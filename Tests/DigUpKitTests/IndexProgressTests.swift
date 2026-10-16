import Testing
@testable import DigUpKit

@Suite struct IndexProgressTests {
    @Test func carriesProgressAcrossPasses() {
        var progress = IndexProgress()
        progress.sync(pending: 8_420)

        let firstPass = progress.progress(passDone: 2_192)
        #expect(firstPass.done == 2_192)
        #expect(firstPass.total == 8_420)

        progress.processed(2_192)
        progress.sync(pending: 6_228)
        let nextPass = progress.progress(passDone: 16)
        #expect(nextPass.done == 2_208)
        #expect(nextPass.total == 8_420)
    }

    @Test func reconcilesWorkAfterHelperStopsBeforeSummary() {
        var progress = IndexProgress()
        progress.sync(pending: 8_420)
        progress.sync(pending: 6_228)

        let nextPass = progress.progress(passDone: 16)
        #expect(nextPass.done == 2_208)
        #expect(nextPass.total == 8_420)
    }

    @Test func includesNewPendingFilesInTheTotal() {
        var progress = IndexProgress()
        progress.sync(pending: 10)
        progress.processed(4)
        progress.sync(pending: 8)

        let nextPass = progress.progress(passDone: 2)
        #expect(nextPass.done == 6)
        #expect(nextPass.total == 12)
    }

    @Test func resetBeginsANewQueue() {
        var progress = IndexProgress()
        progress.sync(pending: 10)
        progress.processed(10)
        progress.reset()
        progress.sync(pending: 3)

        let firstPass = progress.progress(passDone: 1)
        #expect(firstPass.done == 1)
        #expect(firstPass.total == 3)
    }
}
