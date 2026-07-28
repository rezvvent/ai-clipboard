import AppKit
import XCTest
@testable import AIClipboardApp

final class ImageCanonicalizerTests: XCTestCase {
    func testSamePixelsCanonicalizeAcrossPNGAndTIFF() throws {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        NSColor.black.setFill()
        NSRect(x: 5, y: 6, width: 12, height: 9).fill()
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let canonicalTIFF = try XCTUnwrap(ImageCanonicalizer.canonicalPNG(from: tiff))
        let canonicalPNG = try XCTUnwrap(ImageCanonicalizer.canonicalPNG(from: png))
        XCTAssertEqual(canonicalTIFF, canonicalPNG)
    }

    func testTextOrURLPreviewImageIsNotCapturedAsASecondImage() {
        XCTAssertFalse(PasteboardCaptureResolver.prefersImage(
            orderedTypes: [.string, .URL, .tiff],
            hasText: true
        ))
        XCTAssertTrue(PasteboardCaptureResolver.prefersImage(
            orderedTypes: [.png, .tiff, .string],
            hasText: true
        ))
        XCTAssertTrue(PasteboardCaptureResolver.prefersImage(
            orderedTypes: [.tiff],
            hasText: false
        ))
    }

    func testFirstLaunchAlwaysPresentsAutorunBeforeVersionThree() {
        XCTAssertTrue(FirstLaunchPolicy.shouldPresentAutorun(
            version: nil,
            isSnapshotRun: false
        ))
        XCTAssertTrue(FirstLaunchPolicy.shouldPresentAutorun(
            version: 2,
            isSnapshotRun: false
        ))
        XCTAssertFalse(FirstLaunchPolicy.shouldPresentAutorun(
            version: 3,
            isSnapshotRun: false
        ))
    }

    func testObsoleteClipboardFilesAndEncryptionKeysArePurged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIClipboardPurge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Objects"),
            withIntermediateDirectories: true
        )
        for name in [
            "AIClipboard.sqlite",
            "AIClipboard.sqlite-wal",
            "AIClipboard.sqlite-shm",
            "protected-content.key",
            "sync-master.key",
            "settings.json"
        ] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        try Data([1, 2, 3]).write(
            to: directory.appendingPathComponent("Objects/image.png")
        )

        LocalClipboardDataPurger.purge(in: directory)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("AIClipboard.sqlite").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("protected-content.key").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("sync-master.key").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Objects").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("settings.json").path
        ))
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testSignOutPreservesServerSessionForSameAccountLogin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIClipboardAccountSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionURL = directory.appendingPathComponent("sync-session.json")
        let payload: [String: Any] = [
            "endpoint": "https://api.example.com",
            "accessToken": "access",
            "refreshToken": "refresh-token-value",
            "deviceID": UUID().uuidString,
            "cursor": 0,
            "enabled": true,
            "accountEmail": "person@example.com"
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: sessionURL, options: .atomic)

        let coordinator = try SecureSyncCoordinator(
            directory: directory,
            repository: InMemoryClipboardRepository()
        )
        coordinator.activateAccount(email: "person@example.com")
        XCTAssertTrue(coordinator.isConfigured)

        coordinator.activateAccount(email: nil)
        XCTAssertFalse(coordinator.isConfigured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))

        coordinator.activateAccount(email: "person@example.com")
        XCTAssertTrue(coordinator.isConfigured)
        try? FileManager.default.removeItem(at: directory)
    }
}
