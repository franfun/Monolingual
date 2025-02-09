//
//  HelperContext.swift
//  Monolingual
//
//  Created by Ingmar Stein on 10.04.15.
//
//

import Foundation
import os.log

final class HelperContext: NSObject, FileManagerDelegate {

	var request: HelperRequest
	var remoteProgress: ProgressProtocol?
	var progress: Progress?
	private var fileBlacklist = Set<URL>()
	let fileManager = FileManager()
	let isRootless: Bool

	init(_ request: HelperRequest, rootless: Bool) {
		self.request = request
		self.isRootless = rootless

		super.init()

		// exclude the user's trash directory
		seteuid(request.uid)
		for trashURL in fileManager.urls(for: .trashDirectory, in: [.userDomainMask]) {
			excludeDirectory(trashURL)
		}

		// exclude root's trash directory
		seteuid(0)
		for trashURL in fileManager.urls(for: .trashDirectory, in: [.userDomainMask]) {
			excludeDirectory(trashURL)
		}

		fileManager.delegate = self
	}

	func isExcluded(_ url: URL) -> Bool {
		if let excludes = request.excludes {
			let path = url.path
			for exclude in excludes {
				if path.hasPrefix(exclude) {
					return true
				}
			}
		}
		return false
	}

	func excludeDirectory(_ url: URL) {
		if request.excludes != nil {
			request.excludes?.append(url.path)
		} else {
			request.excludes = [url.path]
		}
	}

	func isDirectoryBlacklisted(_ path: URL) -> Bool {
		if let bundle = Bundle(url: path), let bundleIdentifier = bundle.bundleIdentifier, let bundleBlacklist = request.bundleBlacklist {
			return bundleBlacklist.contains(bundleIdentifier)
		}
		return false
	}

	func isFileBlacklisted(_ url: URL) -> Bool {
		return fileBlacklist.contains(url)
	}

	private func addFileDictionaryToBlacklist(_ files: [String: AnyObject], baseURL: URL) {
		for (key, value) in files {
			if let valueDict = value as? [String: AnyObject], let optional = valueDict["optional"] as? Bool, optional {
				continue
			}
			fileBlacklist.insert(baseURL.appendingPathComponent(key))
		}
	}

	func addCodeResourcesToBlacklist(_ url: URL) {
		var codeRef: SecStaticCode?
		// This call might print "MacOS error: -67028" to the console (harmless, but annoying)
		// See rdar://33203786
		let result = SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef)
		if result == errSecSuccess, let code = codeRef {
			var codeInfoRef: CFDictionary?
			// warning: this relies on kSecCSInternalInformation
			let secCSInternalInformation = SecCSFlags(rawValue: 1)
			let result2 = SecCodeCopySigningInformation(code, secCSInternalInformation, &codeInfoRef)
			if result2 == errSecSuccess, let codeInfo = codeInfoRef as? [String: AnyObject] {
				if let resDir = codeInfo["ResourceDirectory"] as? [String: AnyObject] {
					let baseURL: URL

					let contentsDirectory = url.appendingPathComponent("Contents", isDirectory: true)
					if fileManager.fileExists(atPath: contentsDirectory.path) {
						baseURL = contentsDirectory
					} else {
						baseURL = url
					}
					if let files = resDir["files"] as? [String: AnyObject] {
						addFileDictionaryToBlacklist(files, baseURL: baseURL)
					}

					// Version 2 Code Signature (introduced in Mavericks)
					// https://developer.apple.com/library/mac/technotes/tn2206
					if let files = resDir["files2"] as? [String: AnyObject] {
						addFileDictionaryToBlacklist(files, baseURL: baseURL)
					}
				}
			}
		}
	}

	private func appNameForURL(_ url: URL) -> String? {
		let pathComponents = url.pathComponents
		for (i, pathComponent) in pathComponents.enumerated() where (pathComponent as NSString).pathExtension == "app" {
			if let bundleURL = NSURL.fileURL(withPathComponents: Array(pathComponents[0...i])) {
				if let bundle = Bundle(url: bundleURL) {
					var displayName: String?
					if let localization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first,
						let infoPlistStringsURL = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: localization),
						let strings = NSDictionary(contentsOf: infoPlistStringsURL) as? [String: String] {
						displayName = strings["CFBundleDisplayName"]
					}
					if displayName == nil {
						// seems not to be localized?!?
						displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
					}
					if let displayName = displayName {
						return displayName
					}
				}
			}
			return String(pathComponent[..<pathComponent.index(pathComponent.endIndex, offsetBy: -4)])
		}
		return nil
	}

	func reportProgress(url: URL, size: Int) {
		let appName = appNameForURL(url)

		if let progress = self.progress {
			progress.fileCompletedCount = (progress.fileCompletedCount ?? 0) + 1
			progress.fileURL = url
			progress.setUserInfoObject(size, forKey: ProgressUserInfoKey.sizeDifference)
			if let appName = appName {
				progress.setUserInfoObject(appName, forKey: ProgressUserInfoKey.appName)
			}
			progress.totalUnitCount += Int64(size)
			progress.completedUnitCount += Int64(size)

			// show the file progress even if it has zero bytes
			if size == 0 {
				progress.willChangeValue(for: \.completedUnitCount)
				progress.didChangeValue(for: \.completedUnitCount)
			}
		}

		if let progress = remoteProgress {
			progress.processed(file: url.path, size: size, appName: appName)
		}
	}

	func remove(_ url: URL) {
		var error: Error?
		if request.trash {
			if request.dryRun {
				return
			}

			var dstURL: NSURL?

			// trashItemAtURL does not call any delegate methods (radar 20481813)

			var fileSize: [URL: Int] = [:]

			// check if any file below `url` has been blacklisted and record sizes
			if let dirEnumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey], options: [], errorHandler: nil) {
				for entry in dirEnumerator {
					guard let theURL = entry as? URL else { continue }
					if isFileBlacklisted(theURL) {
						return
					}

					do {
						let resourceValues = try theURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey])
						if let size = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
							fileSize[theURL] = size
						}

						// change owner so that it can be moved to the user's trash
						// see https://github.com/IngmarStein/Monolingual/issues/110
						let attributes: [FileAttributeKey: Any]
						if let isDirectory = resourceValues.isDirectory, isDirectory {
							attributes = [.ownerAccountID: request.uid, .posixPermissions: S_IRWXU]
						} else {
							attributes = [.ownerAccountID: request.uid]
						}
						try fileManager.setAttributes(attributes, ofItemAtPath: theURL.path)
					} catch {
					}
				}
			}

			let parent = url.deletingLastPathComponent()
			let parentAttributes = try? fileManager.attributesOfItem(atPath: parent.path)

			do {
				try fileManager.setAttributes([.ownerAccountID: request.uid, .posixPermissions: S_IRWXU], ofItemAtPath: url.path)
				try fileManager.setAttributes([.ownerAccountID: request.uid, .posixPermissions: S_IRWXU], ofItemAtPath: parent.path)
			} catch let error {
				os_log("Failed to set owner: %@", error.localizedDescription)
			}

			// try to move the file to the user's trash
			var success = false
			seteuid(request.uid)
			do {
				try fileManager.trashItem(at: url, resultingItemURL: &dstURL)
				success = true
			} catch let error1 {
				error = error1
				os_log("Could not move %@ to trash: %@", url.absoluteString, error!.localizedDescription)
				success = false
			}
			seteuid(0)
			if !success {
				do {
					// move the file to root's trash
					try self.fileManager.trashItem(at: url, resultingItemURL: &dstURL)
					success = true
				} catch let error1 {
					error = error1
					success = false
				}
			}

			if let parentAttributes = parentAttributes {
				try? fileManager.setAttributes(parentAttributes, ofItemAtPath: parent.path)
			}

			if success {
				for (url, size) in fileSize {
					reportProgress(url: url, size: size)
				}
			} else if let error = error {
				os_log("Error trashing '%@': %@", type: .error, url.path, error.localizedDescription)
			}
		} else {
			do {
				try self.fileManager.removeItem(at: url)
			} catch let error1 {
				error = error1
				if let error = error as NSError? {
					if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlyingError.domain == NSPOSIXErrorDomain && underlyingError.code == Int(ENOTEMPTY) {
						// ignore non-empty directories (they might contain blacklisted files and cannot be removed)
					} else {
						os_log("Error removing '%@': %@", type: .error, url.path, error)
					}
				}
			}
		}
	}

	private func fileManager(_ fileManager: FileManager, shouldProcessItemAtURL url: URL) -> Bool {
		if request.dryRun || isFileBlacklisted(url) || (isRootless && url.isProtected) {
			return false
		}

		// TODO: it is wrong to report process here, deletion might fail
		do {
			let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
			if let size = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
				reportProgress(url: url, size: size)
			}
		} catch {
		}
		return true
	}

	// MARK: - NSFileManagerDelegate

	func fileManager(_ fileManager: FileManager, shouldRemoveItemAt url: URL) -> Bool {
		return self.fileManager(fileManager, shouldProcessItemAtURL: url)
	}

	func fileManager(_ fileManager: FileManager, shouldProceedAfterError error: Error, removingItemAt url: URL) -> Bool {
		// https://github.com/IngmarStein/Monolingual/issues/102
		// os_log("Error removing '%@': %@", type: .error, url.path, error as NSError)

		return true
	}

}
