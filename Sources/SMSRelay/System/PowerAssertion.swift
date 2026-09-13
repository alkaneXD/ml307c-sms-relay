import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while held. Display sleep is still allowed.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var isHeld = false

    func hold(reason: String) {
        guard !isHeld else { return }
        let kr = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        isHeld = kr == kIOReturnSuccess
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        id = 0
        isHeld = false
    }

    deinit { release() }
}
