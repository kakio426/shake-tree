import Foundation
import IOKit.pwr_mgt

/// Small injectable boundary for native assertions, including failure/recovery tests.
@MainActor
struct AwakeAssertionClient {
    var create: (AwakeMode, TimeInterval?) -> (IOReturn, IOPMAssertionID)
    var release: (IOPMAssertionID) -> Void
    var type: (IOPMAssertionID) -> String?

    static var live: Self {
        Self(create: { mode, duration in
            var properties: [String: Any] = [
                kIOPMAssertionTypeKey as String: mode.assertionType,
                kIOPMAssertionNameKey as String: "Shake Tree Keep Awake",
                kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            ]
            if let duration {
                properties[kIOPMAssertionTimeoutKey as String] = duration
                properties[kIOPMAssertionTimeoutActionKey as String] = kIOPMAssertionTimeoutActionRelease
            }
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
            return (status, id)
        }, release: { IOPMAssertionRelease($0) }, type: { id in
            let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
            return properties?[kIOPMAssertionTypeKey as String] as? String
        })
    }
}
