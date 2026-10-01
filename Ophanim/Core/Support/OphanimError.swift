import AudioToolbox
import Foundation
import SwiftUI

enum OphanimError: Error {
    case infoPlistNotFound
    case waitInstallation
    case appEncrypted
    case appCorrupted
    case appProhibited
    case appMaliciousProhibited
    case failedToStripBinary
    case invalidUserDylib
    case invalidFolderName
}

extension OphanimError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .infoPlistNotFound:
            return NSLocalizedString("error.corruptedIPA", comment: "")
        case .waitInstallation:
            return NSLocalizedString("error.waitInstallation", comment: "")
        case .appEncrypted:
            return NSLocalizedString("error.appEncrypted", comment: "")
        case .appCorrupted:
            return NSLocalizedString("error.appCorrupted", comment: "")
        case .appProhibited:
            return NSLocalizedString("error.appProhibited", comment: "")
        case .appMaliciousProhibited:
            return NSLocalizedString("error.appMaliciousProhibited", comment: "")
        case .failedToStripBinary:
            return NSLocalizedString("error.failedToStripBinary", comment: "")
        case .invalidUserDylib:
            return NSLocalizedString("error.invalidUserDylib", comment: "")
        case .invalidFolderName:
            return NSLocalizedString("error.invalidFolderName", comment: "")
        }
    }
}
