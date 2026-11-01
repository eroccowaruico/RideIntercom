import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct XcodeValidationTests {
    @Test func sharedSchemesSeparateTestFromNormalRunAndArchive() throws {
        for (name, configuration) in [("RideIntercom", "Debug-Validation"), ("RideIntercomAudioE2E", "Debug-Validation"), ("RideIntercom-StoreKitTests", "Debug-Validation"), ("RideIntercom-StoreKitUITests", "Debug-Validation")] {
            let scheme = try AppTestSupport.source("RideIntercom.xcodeproj/xcshareddata/xcschemes/\(name).xcscheme")
            for (action, value) in [("TestAction", configuration), ("LaunchAction", "Debug"), ("ArchiveAction", "Release")] {
                #expect(scheme.range(of: "<\(action)\\b[^>]*buildConfiguration\\s*=\\s*\"\(value)\"", options: .regularExpression) != nil)
            }
            let fixtureSettings: String
            if name == "RideIntercom-StoreKitTests" {
                #expect(scheme.contains("container:Configuration/StoreKit.xctestplan"))
                fixtureSettings = try AppTestSupport.source("Configuration/StoreKit.xctestplan")
            } else {
                fixtureSettings = scheme
            }
            #expect(fixtureSettings.contains("RIDEINTERCOM_LOCAL_TESTING"))
            #expect(fixtureSettings.contains("signed-out"))
        }
    }

    @Test func nativeTargetsAndProjectHaveTheirExplicitValidationConfigurations() throws {
        let data = try Data(contentsOf: AppTestSupport.workspaceRoot().appending(path: "RideIntercom.xcodeproj/project.pbxproj"))
        let project = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let rootID = try #require(project["rootObject"] as? String)
        let projectObject = try #require(objects[rootID])
        let targetIDs = try #require(projectObject["targets"] as? [String])
        let nativeTargets = targetIDs.compactMap { objects[$0] }.filter { $0["isa"] as? String == "PBXNativeTarget" }
        let targetNames = Set(nativeTargets.compactMap { $0["name"] as? String })
        let requiredTargets: Set<String> = ["RideIntercom", "RideIntercomWidgets", "RideIntercomWatch",
                                            "RideIntercomTests", "RideIntercomUITests", "RideIntercomAudioE2ETests"]
        #expect(requiredTargets.isSubset(of: targetNames))
        #expect(!objects.values.contains { $0["isa"] as? String == "PBXAggregateTarget" })
        let requiredConfigurations: Set<String> = ["Debug", "Release", "Debug-Validation", "Release-Validation"]
        for owner in [projectObject] + nativeTargets {
            let listID = try #require(owner["buildConfigurationList"] as? String)
            let list = try #require(objects[listID])
            #expect(list["isa"] as? String == "XCConfigurationList")
            let ids = try #require(list["buildConfigurations"] as? [String])
            let names = Set(ids.compactMap { objects[$0]?["name"] as? String })
            #expect(requiredConfigurations == names)
            let releaseValidation = try #require(ids.compactMap { objects[$0] }.first { $0["name"] as? String == "Release-Validation" })
            let settings = try #require(releaseValidation["buildSettings"] as? [String: Any])
            let conditions = (settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] as? String ?? "").split { $0.isWhitespace }
            #expect(!conditions.contains("DEBUG"))
        }
        let projectList = try #require(projectObject["buildConfigurationList"] as? String)
        let configIDs = try #require(objects[projectList]?["buildConfigurations"] as? [String])
        let release = try #require(configIDs.compactMap { objects[$0] }.first { $0["name"] as? String == "Release" })
        let releaseSettings = try #require(release["buildSettings"] as? [String: Any])
        #expect(releaseSettings["RIDEINTERCOM_STORAGE_NAMESPACE"] as? String == "RideIntercom")
        #expect(release["baseConfigurationReference"] == nil)
        #expect(releaseSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] == nil)
        let releaseValidation = try #require(configIDs.compactMap { objects[$0] }.first { $0["name"] as? String == "Release-Validation" })
        let releaseValidationSettings = try #require(releaseValidation["buildSettings"] as? [String: Any])
        #expect(releaseValidationSettings["RIDEINTERCOM_STORAGE_NAMESPACE"] as? String == "RideIntercom.Validation.Xcode")
        #expect(releaseValidationSettings["ENABLE_TESTABILITY"] as? String == "YES")
        #expect(releaseValidation["baseConfigurationReference"] == nil)
        #expect((releaseValidationSettings["SWIFT_OPTIMIZATION_LEVEL"] as? String ?? "-O") == (releaseSettings["SWIFT_OPTIMIZATION_LEVEL"] as? String ?? "-O"))
        #expect(releaseValidationSettings["SWIFT_COMPILATION_MODE"] as? String == releaseSettings["SWIFT_COMPILATION_MODE"] as? String)
        let app = try #require(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "RideIntercom" })
        let appListID = try #require(app["buildConfigurationList"] as? String)
        let appConfigIDs = try #require(objects[appListID]?["buildConfigurations"] as? [String])
        let appRelease = try #require(appConfigIDs.compactMap { objects[$0] }.first { $0["name"] as? String == "Release" })
        let appReleaseSettings = try #require(appRelease["buildSettings"] as? [String: Any])
        #expect(appReleaseSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "com.yowamushi-inc.RideIntercom.RideIntercom")
        #expect(appReleaseSettings["RIDEINTERCOM_STORAGE_NAMESPACE"] as? String == "RideIntercom")
        #expect(appRelease["baseConfigurationReference"] == nil)
        let validation = try AppTestSupport.source("Configuration/Validation.xcconfig")
        #expect(validation.contains("RIDEINTERCOM_VALIDATION"))
        #expect(validation.contains("RideIntercom.Validation.Xcode"))
        #expect(!validation.contains("#include"))
        #expect(!FileManager.default.fileExists(atPath: AppTestSupport.workspaceRoot().appending(path: "Configuration/StoreKitValidation.xcconfig").path))
    }

    @Test func watchTargetCompilesTheSharedSystemScope() throws {
        let data = try Data(contentsOf: AppTestSupport.workspaceRoot().appending(path: "RideIntercom.xcodeproj/project.pbxproj"))
        let project = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let watch = try #require(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "RideIntercomWatch" })
        let phaseIDs = try #require(watch["buildPhases"] as? [String])
        let sources = phaseIDs.compactMap { objects[$0] }.filter { $0["isa"] as? String == "PBXSourcesBuildPhase" }
        let files = sources.flatMap { $0["files"] as? [String] ?? [] }
        let references = files.compactMap { objects[$0]?["fileRef"] as? String }
        let paths = references.compactMap { objects[$0]?["path"] as? String }
        #expect(paths.contains("RideIntercom/SystemSurfaces/Shared/SystemSurfaceScope.swift"))
    }

    @Test func localSwiftPackageRootsAreExcludedFromTheAppsSynchronizedResources() throws {
        let data = try Data(contentsOf: AppTestSupport.workspaceRoot().appending(path: "RideIntercom.xcodeproj/project.pbxproj"))
        let project = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let app = try #require(objects.first { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == "RideIntercom" })
        let groupIDs = try #require(app.value["fileSystemSynchronizedGroups"] as? [String])
        let packages = objects.values.filter { $0["isa"] as? String == "XCLocalSwiftPackageReference" }
            .compactMap { $0["relativePath"] as? String }
        #expect(!packages.isEmpty)
        for groupID in groupIDs {
            let group = try #require(objects[groupID])
            let path = try #require(group["path"] as? String)
            let exceptions = (group["exceptions"] as? [String] ?? []).compactMap { objects[$0] }
                .filter { $0["target"] as? String == app.key }
            let excluded = Set(exceptions.flatMap { $0["membershipExceptions"] as? [String] ?? [] })
            for package in packages where package.hasPrefix(path + "/") {
                // Each package is an opaque container to Xcode. Excluding only
                // its parent folder doesn't exclude that resource container.
                #expect(excluded.contains(String(package.dropFirst(path.count + 1))))
            }
        }
    }

    @Test func allSystemSurfaceProductsCarryTheBuildsStorageNamespace() throws {
        for product in ["RideIntercom", "RideIntercomWidgets", "RideIntercomWatch"] {
            let data = try Data(contentsOf: AppTestSupport.workspaceRoot().appending(path: "\(product)/Info.plist"))
            let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            #expect(info["StorageNamespace"] as? String == "$(RIDEINTERCOM_STORAGE_NAMESPACE)")
        }
        let namespace = try #require(Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String)
        #expect(namespace.hasPrefix("RideIntercom.Validation."))
        #expect(!SystemSurfaceScope.permitsSystemAccess)
        #expect(!NotificationSystem.permitsSystemAccess)
    }

    @Test(arguments: [nil, "", "$(RIDEINTERCOM_STORAGE_NAMESPACE)", "RideIntercom.Validation.Xcode", "RideIntercom.AudioE2E.Host", "RideIntercom.Validation.run.ios-tests", "RideIntercom.other"] as [String?])
    func isolatedScopesNeverResolveTheProductionAppGroupOrReloadWidgets(namespace: String?) {
        var resolutions = 0, reloads = 0
        let store = WidgetDestinationStore.system(storageNamespace: namespace) {
            resolutions += 1
            return FileManager.default.temporaryDirectory
        }
        #expect(!SystemSurfaceScope.permitsSystemAccess(storageNamespace: namespace))
        #expect(store.fileURL == nil)
        #expect(store.readSnapshot() == nil)
        let publisher = WidgetDestinationPublisher(store: store, reload: { reloads += 1 })
        publisher.publish([])
        #expect(resolutions == 0)
        #expect(reloads == 0)
    }

    @Test func normalAppKeepsItsSystemSurfaceContainer() {
        var resolutions = 0
        let directory = FileManager.default.temporaryDirectory
        let store = WidgetDestinationStore.system(storageNamespace: "RideIntercom") {
            resolutions += 1
            return directory
        }
        #expect(SystemSurfaceScope.permitsSystemAccess(storageNamespace: "RideIntercom"))
        #expect(resolutions == 1)
        #expect(store.fileURL == directory.appending(path: "call-destinations.json"))
    }

    #if DEBUG && RIDEINTERCOM_VALIDATION
    @Test func validationAccountFactoryUsesExplicitFixtureAndRejectsUnsafeScopes() {
        for namespace in ["", "$(RIDEINTERCOM_STORAGE_NAMESPACE)", "RideIntercom", "RideIntercom.AudioE2E.Host"] {
            #expect(AppleAccountFixture.makeForCurrentProcess(namespace: namespace) == nil)
        }
        let account = AppleAccountSession.makeForCurrentProcess()
        #expect(account.userID == nil)
        #expect(!account.storageUnavailable)
    }

    @Test func recoveryFixtureUsesRealRepositoryAndChecksBothEmptyManifestAndArchivedBytes() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "RecoveryValidation-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        let namespace = "RideIntercom.Validation.unit", fixtureID = UUID()
        try AppleAccountFixture.processGroupRecovery("prepare:\(fixtureID)", namespace: namespace, applicationSupport: support)
        let directory = support.appending(path: AppleAccountSession.storageNamespace(base: namespace, userID: AppleAccountFixture.userID)).appending(path: "Groups")
        let file = FileGroupStore(directory: directory)
        let repository = GroupRepository(store: file, credentials: InMemoryGroupCredentialStore())
        #expect(throws: (any Error).self) { _ = try repository.load(localMemberID: "fixture") }
        #expect(throws: (any Error).self) {
            try AppleAccountFixture.processGroupRecovery("verify:\(fixtureID)", namespace: namespace, applicationSupport: support)
        }
        try repository.reset()
        try AppleAccountFixture.processGroupRecovery("verify:\(fixtureID)", namespace: namespace, applicationSupport: support)
        #expect(throws: (any Error).self) {
            try AppleAccountFixture.processGroupRecovery("verify:\(UUID())", namespace: namespace, applicationSupport: support)
        }
        let archive = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("groups-corrupt-") })
        try Data("different bytes".utf8).write(to: archive)
        #expect(throws: (any Error).self) {
            try AppleAccountFixture.processGroupRecovery("verify:\(fixtureID)", namespace: namespace, applicationSupport: support)
        }
    }

    @Test func recoveryFixtureRejectsOrdinaryScopeAndSymlinkWithoutTouchingOtherData() throws {
        let fixtureID = UUID()
        let support = FileManager.default.temporaryDirectory.appending(path: "RecoveryBoundary-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(throws: (any Error).self) {
            try AppleAccountFixture.processGroupRecovery("prepare:\(fixtureID)", namespace: "RideIntercom", applicationSupport: support)
        }
        #expect(!FileManager.default.fileExists(atPath: support.path))
        let namespace = "RideIntercom.Validation.unit"
        let scoped = support.appending(path: AppleAccountSession.storageNamespace(base: namespace, userID: AppleAccountFixture.userID))
        let foreign = support.appending(path: "ordinary")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let sentinel = foreign.appending(path: "groups.json")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: scoped, withDestinationURL: foreign)
        #expect(throws: (any Error).self) {
            try AppleAccountFixture.processGroupRecovery("prepare:\(fixtureID)", namespace: namespace, applicationSupport: support)
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }
    #endif
}
