//
//  OphanimError.swift
//  Ophanim
//
//  Shared install/launch failure cases surfaced through Log and Toast.
//

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
    case containerRunning
    case containerActive
    case corruptedFile(String, String)
    case unsupportedPlatform(String, String)
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
        case .containerRunning:
            return NSLocalizedString("error.containerRunning", value: "Quit the app before changing its container.", comment: "")
        case .corruptedFile(let name, let reason):
            let template = NSLocalizedString("error.corruptedFile", value: "%@ is unusable: %@.", comment: "")
            return String(format: template, name, reason)
        case .unsupportedPlatform(let bid, let platform):
            let template = NSLocalizedString("error.unsupportedPlatform", value: "%@: cannot run here (%@).", comment: "")
            return String(format: template, bid, platform)
        case .containerActive:
            return NSLocalizedString("error.containerActive", value: "This is the active container. Switch to another one first.", comment: "")
        }
    }
}
