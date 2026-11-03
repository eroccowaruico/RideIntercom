import XCTest
import CryptoKit

final class RideIntercomUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        launchApp()
    }

    private func launchApp(startOnDiagnostics: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        if name.contains("CorruptGroupStoreRecovery") {
            app.launchEnvironment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"] = "prepare:\(UUID())"
        }
        if name.contains("InternetEnrollmentThrottle") {
            app.launchEnvironment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] = "throttled"
        }
        if name.contains("AccountReplacement") {
            app.launchEnvironment["RIDEINTERCOM_ACCOUNT_REPLACEMENT_FIXTURE"] = UUID().uuidString
        }
        if name.contains("Adaptive") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        app.activate()

        if name.contains("AccountReplacement") {
            XCTAssertTrue(app.descendants(matching: .any)["accountDataResetScreen"].firstMatch.waitForExistence(timeout: 5))
            return
        }
        XCTAssertTrue(waitForVisibleRoot(in: app), "Expected the app to launch into a visible root screen")
        removeExistingTalkGroups()
        removeExistingSavedUsers()

        if startOnDiagnostics {
            openDiagnosticsTab()
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    @MainActor
    func testInvitationShareUsesSystemSheetAndReturnsToCall() throws {
        createTalkGroupAndOpenCall()
        assertAdvancedCallHasNoManagementControls()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        openTalkGroupManagement()
        XCTAssertTrue(app.buttons["groupSettingsAddMembersButton"].exists)
        copyManagementInvitation()
        attachScreen("Advanced group management after native invitation sharing")
        closeManagementAndReturnToCall()
        XCTAssertTrue(app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
        XCTAssertFalse(app.staticTexts["groupErrorLabel"].exists)
    }

    #if os(iOS)
    @MainActor
    func testStandardInvitationCancelAndCopyPreservePeople() throws {
        let suffix = UUID().uuidString
        let existingRider = "Existing Rider \(suffix)"
        try openSavedUserInvitation(inviter: "ui-share-\(suffix)", sharedName: existingRider)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.waitForExistence(timeout: 3))
        openSettingsTab()
        selectSettingsLayout("Standard")
        app.tabBars.buttons["Users"].tap()
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.waitForExistence(timeout: 3))
        let savedUsers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
        let savedUserCount = savedUsers.count
        app.openCurrentCall()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 5))
        revealStandardCallElement(app.staticTexts[existingRider].firstMatch)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.exists)
        // The invitation sits in the call's More menu, not as a standalone share button.
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        let invite = app.openCallMoreMenuItem("inviteButton")
        invite.tap()
        let copy = app.cells.matching(NSPredicate(format: "label == 'Copy' OR label == 'Copy Link'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        // Dismiss without choosing a share destination. From the menu the share sheet is a
        // popover anchored to the toolbar, so tap outside it rather than swiping it down.
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        if outside.exists { outside.tap() } else { app.swipeDown() }
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        revealStandardCallElement(app.staticTexts[existingRider].firstMatch)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 2"].exists)
        app.openCallMoreMenuItem("inviteButton").tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        revealStandardCallElement(app.staticTexts[existingRider].firstMatch)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 2"].exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 3"].exists)
        app.closeCallIfOpen()
        app.tabBars.buttons["Users"].tap()
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(savedUsers.count, savedUserCount)
        XCTAssertFalse(app.staticTexts["Invited Rider 2"].exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 3"].exists)
        app.terminate(); app.launch(); app.activate()
        openSettingsTab()
        selectSettingsLayout("Standard")
        app.tabBars.buttons["Groups"].tap()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", "Talk Group")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        revealStandardCallElement(app.staticTexts[existingRider].firstMatch)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 2"].exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 3"].exists)
    }

    @MainActor
    private func revealStandardCallElement(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews["standardCallScreen"]
        XCTAssertTrue(list.waitForExistence(timeout: 3), file: file, line: line)
        for down in [false, true] {
            for _ in 0..<6 {
                if element.exists && element.isHittable { return }
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        XCTAssertTrue(element.isHittable, "Expected the Call control after scrolling", file: file, line: line)
    }

    #endif

    @MainActor
    func testInternetEnrollmentThrottleKeepsAccountAndShowsRetryInstruction() throws {
        openInternetSettings()
        let url = app.textFields["internetWorkerURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 3))
        url.tap(); url.typeText("https://account.test")
        let prepare = app.buttons["prepareInternetAppleSignIn"]
        prepare.tap()
        let status = app.staticTexts["internetAppleSignInStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("Too many sign-in attempts"))
        XCTAssertTrue(status.label.contains("Set Up Internet Calling again"))
        XCTAssertFalse(app.buttons["internetAppleSignInButton"].isEnabled)
        prepare.tap()
        XCTAssertTrue(status.label.contains("Wait"))
        attachScreen("Internet Enrollment Retry Instruction")
        app.buttons["closeInternetConnection"].tap()
        for _ in 0..<6 where !app.buttons["signOutButton"].exists { app.swipeDown() }
        XCTAssertTrue(app.buttons["signOutButton"].exists)
        XCTAssertFalse(app.otherElements["appleSignInScreen"].exists)
    }

    @MainActor
    func testInternetAppleSetupKeepsLocalLoginWhenRegistrationIsUnavailable() throws {
        openInternetSettings()
        let url = app.textFields["internetWorkerURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 3))
        url.tap(); url.typeText("https://account.test")
        app.buttons["prepareInternetAppleSignIn"].tap()
        let status = app.staticTexts["internetAppleSignInStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("unavailable"))
        attachScreen("Internet Apple Setup Unavailable with Local Login Retained")
        app.buttons["closeInternetConnection"].tap()
        for _ in 0..<6 where !app.buttons["signOutButton"].exists { app.swipeDown() }
        XCTAssertFalse(app.otherElements["appleSignInScreen"].exists)
        XCTAssertTrue(app.buttons["signOutButton"].exists)
    }

    @MainActor
    func testPersonalAndReceivedNamesCanBeEditedAndRestored() throws {
        openSettingsTab()
        let ownName = app.textFields["localDisplayNameField"]
        revealSettingsControl(ownName)
        ownName.tap()
        ownName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (ownName.value as? String ?? "").count) + "Snow Cat")
        app.buttons["saveLocalDisplayNameButton"].tap()
        XCTAssertTrue(app.staticTexts["localDisplayNameSaved"].waitForExistence(timeout: 3))
        try openSavedUserInvitation(inviter: "ui-name-rider", sharedName: "Mountain Rider")
        openGroupsTab(); app.buttons["standardCreateGroupButton"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editUser-")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3)); edit.tap()
        let original = app.descendants(matching: .any)["savedUserOriginalName"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        let name = app.textFields["savedUserNameField"]
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "Ski Friend")
        app.buttons["saveUserNameButton"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 3)); edit.tap()
        XCTAssertEqual(app.textFields["savedUserNameField"].value as? String, "Ski Friend")
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        attachScreen("Local Alias and Original Shared Name")
        let originalText = original.label + (original.value as? String ?? "") + original.staticTexts.allElementsBoundByIndex.map(\.label).joined()
        XCTAssertTrue(originalText.contains("Mountain Rider"))
        app.buttons["resetUserNameButton"].tap()
        let user = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "selectUser-")).firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 3)); XCTAssertTrue(user.label.contains("Mountain Rider"))
        app.buttons["closeSavedUsersButton"].tap()
        app.terminate(); app.launch(); app.activate()
        openSettingsTab()
        revealSettingsControl(ownName)
        XCTAssertEqual(ownName.value as? String, "Snow Cat")
    }

    @MainActor
    func testAccountReplacementCanRemoveOldDataAndSetUpAgainWithoutAppleVerification() throws {
        let reset = app.descendants(matching: .any)["accountDataResetScreen"].firstMatch
        let remove = app.buttons["removePreviousAccountDataButton"]
        XCTAssertTrue(reset.exists)
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].exists)
        remove.tap()
        let confirm = app.buttons["confirmAccountDataResetButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertTrue(reset.exists)
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        attachScreen("Previous Account Data Cleanup")
        remove.tap()
        confirm.tap()
        let finish = app.buttons["finishAccountDeletionButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["verifyAppleDeletionButton"].exists)
        XCTAssertFalse(app.links["Open Apple Account"].exists)
        attachScreen("Previous Data Removed New Account Kept")
        finish.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appleSignInScreen"].firstMatch.waitForExistence(timeout: 3))
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(waitForVisibleRoot(in: app))
        XCTAssertFalse(reset.exists)
        createTalkGroupAndOpenCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAccountDeletionConfirmsScopeEndsCallAndReturnsToSignIn() throws {
        createTalkGroupAndOpenCall()
        openSettingsTab()
        let deletion = app.buttons["deleteAccountButton"]
        for _ in 0..<6 where !deletion.isHittable { app.swipeDown() }
        XCTAssertTrue(deletion.waitForExistence(timeout: 3)); deletion.tap()
        let erase = app.buttons["deleteWithoutAppleButton"]
        XCTAssertTrue(erase.waitForExistence(timeout: 3))
        // Cancelling the sheet preserves the live account and groups.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 3)); deletion.tap()
        for _ in 0..<6 where !erase.isHittable { app.swipeUp() }
        erase.tap()
        let confirmation = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3)); confirmation.tap()
        let finish = app.buttons["finishAccountDeletionButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Apple authorization has not been removed")).firstMatch.exists)
        XCTAssertFalse(app.buttons["disconnectButton"].exists)
        attachScreen("Local Account Deletion with Explicit Apple Removal")
        finish.tap()
        XCTAssertTrue(app.buttons["signInWithAppleButton"].firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch(); app.activate() // The isolated native-login fixture signs in again.
        openGroupsTab()
        XCTAssertFalse(app.buttons["disconnectButton"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-")).firstMatch.exists)
    }

    @MainActor
    func testSignOutEndsCallAndReturnsToAppleSignIn() throws {
        createTalkGroupAndOpenCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        openSettingsTab()
        let signOut = app.buttons["signOutButton"]
        for _ in 0..<6 where !signOut.isHittable { app.swipeDown() }
        XCTAssertTrue(signOut.waitForExistence(timeout: 3))
        signOut.tap()
        let confirmation = app.buttons["confirmSignOutButton"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()
        XCTAssertTrue(app.buttons["signInWithAppleButton"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["disconnectButton"].exists)
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].exists)
        attachScreen("Signed Out Apple Login")
    }


    /// The simulator keeps saved riders between runs, and a rider ID seen again with a new
    /// key is an identity conflict. Each test run therefore uses its own rider IDs; within the
    /// run the same inviter keeps one ID and key, so restarts still find the saved rider.
    private let inviterRun = UUID().uuidString.prefix(8).lowercased()

    @MainActor
    private func openSavedUserInvitation(inviter: String, sharedName: String? = nil) throws {
        let memberID = inviter + "-" + inviterRun
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: Data(SHA256.hash(data: Data(memberID.utf8))))
        app.open(try InvitationURLFixture.make(inviter: memberID, sharedName: sharedName, signingKey: signingKey))
        XCTAssertTrue(app.descendants(matching: .any)["remoteParticipantRow0"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testDirectCallsReuseUserDestinationWithoutAddingParticipants() throws {
        try openSavedUserInvitation(inviter: "ui-direct-rider")
        openUsersTab()
        let user = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-")).firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 3))
        user.tap()
        // The invitation's group is still connected, so choosing the person asks before switching.
        let confirm = app.buttons["switchCallConfirmButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["directCallHelpLabel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
        openUsersTab()
        let userID = String(user.identifier.dropFirst("standardUser-".count))
        let userRow = app.buttons["standardUser-" + userID].firstMatch
        openRowSettings(userRow, "User Settings", view: "userSettingsView")
        XCTAssertFalse(app.buttons["groupSettingsAddMembersButton"].exists)
        copyManagementInvitation(identifier: "userSettingsInviteButton", view: "userSettingsView")
        closeManagementAndReturnToCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        attachScreen("Individual Call with Saved User")
        openGroupsTab()
        XCTAssertTrue(app.buttons["standardCurrentCallButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-")).containing(.staticText, identifier: "Direct Call").firstMatch.exists)
        attachScreen("Users and Groups with Current Individual Call")
        app.terminate(); app.launch(); app.activate()
        openUsersTab()
        XCTAssertTrue(user.waitForExistence(timeout: 3))
        user.tap()
        XCTAssertTrue(app.staticTexts["directCallHelpLabel"].waitForExistence(timeout: 3))
        if app.buttons["connectButton"].exists { app.buttons["connectButton"].tap() }
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        // Removing the directory entry leaves the selected call and its stop control available.
        openGroupsTab()
        app.buttons["standardCreateGroupButton"].tap()
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "selectUser-")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 3))
        app.buttons["closeSavedUsersButton"].tap()
        openUsersTab()
        XCTAssertFalse(user.exists)
        XCTAssertFalse(userRow.exists, "Removed users cannot open User Settings")
        app.buttons["standardCurrentCallButton"].tap()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertTrue(app.staticTexts["directCallHelpLabel"].label.contains("removed from Saved Users"))
        attachScreen("Individual Call Retained after User Removal")
        app.buttons["disconnectButton"].tap()
        try checkGroupDeletionCanBeExercisedFromUI()
    }

    /// Adding saved users only lists them locally. The sheet stays open on the
    /// invitation step so the group key can reach them before it is dismissed.
    @MainActor
    private func finishSendingGroupInvitation(_ screen: String) {
        XCTAssertTrue(app.staticTexts["sendGroupInvitationMessage"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["addedUsersInviteButton"].exists)
        attachScreen(screen)
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testSavedUsersSurviveGroupDeletionAndCanBeReused() throws {
        try openSavedUserInvitation(inviter: "ui-saved-rider")
        try checkGroupDeletionCanBeExercisedFromUI()
        // Restart only here: this case explicitly verifies persisted users.
        app.terminate(); app.launch(); app.activate()
        openUsersTab()
        let savedUserRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-")).firstMatch
        openRowSettings(savedUserRow, "User Settings", view: "userSettingsView")
        let field = app.textFields["savedUserNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "Alex")
        app.buttons["saveUserNameButton"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        openGroupsTab()
        app.buttons["standardCreateGroupButton"].tap()
        let firstUser = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "selectUser-")).firstMatch
        XCTAssertTrue(firstUser.waitForExistence(timeout: 3))
        let toggle = app.switches[firstUser.identifier]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertTrue(toggle.label.contains("Alex"))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        attachScreen("Saved Users Selection")
        app.buttons["saveUserSelectionButton"].tap()
        finishSendingGroupInvitation("New Group with Saved User invitation step")
        XCTAssertTrue(app.descendants(matching: .any)["remoteParticipantRow0"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.exists)
        assertAdvancedCallHasNoManagementControls()
        openTalkGroupManagement()
        XCTAssertTrue(app.buttons["groupSettingsInviteButton"].exists)
        attachScreen("Group Created from Saved User management")
        closeManagementAndReturnToCall()
        try checkGroupDeletionCanBeExercisedFromUI()
        createTalkGroupAndOpenCall()
        assertAdvancedCallHasNoManagementControls()
        openTalkGroupManagement()
        let add = app.buttons["groupSettingsAddMembersButton"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["saveUserSelectionButton"].tap()
        finishSendingGroupInvitation("Saved User Added invitation step")
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        attachScreen("Saved User Added to Existing Group management")
        closeManagementAndReturnToCall()
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
        openGroupsTab()
        app.buttons["standardCreateGroupButton"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 3))
        attachScreen("Saved User Removed while Group Remains")
        app.buttons["closeSavedUsersButton"].tap()
        talkGroupRows.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
        openTalkGroupManagement()
        // Member names change from the row's swipe or menu in Group Settings.
        let participant = app.staticTexts["Alex"].firstMatch
        XCTAssertTrue(participant.waitForExistence(timeout: 3))
        participant.swipeLeft()
        app.buttons["Edit Name"].firstMatch.tap()
        let memberName = app.textFields["groupMemberNameField"]
        XCTAssertTrue(memberName.waitForExistence(timeout: 3))
        memberName.tap()
        memberName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (memberName.value as? String)?.count ?? 0) + "Group Alex")
        app.buttons["saveGroupMemberNameButton"].tap()
        let renamed = app.staticTexts["Group Alex"].firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 3))
        attachScreen("Advanced group participant name edited in management")
        renamed.swipeLeft()
        let removeMember = app.buttons["Delete"].firstMatch
        XCTAssertTrue(removeMember.waitForExistence(timeout: 3))
        removeMember.tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 3))
        closeManagementAndReturnToCall()
        XCTAssertTrue(app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].firstMatch.waitForExistence(timeout: 3))
        try checkGroupDeletionCanBeExercisedFromUI()
        app.terminate(); app.launch(); app.activate()
        openGroupsTab()
        app.buttons["standardCreateGroupButton"].tap()
        XCTAssertFalse(toggle.exists)
        app.buttons["closeSavedUsersButton"].tap()
    }

    @MainActor
    func testAACBitrateChoicesSurviveCodecSwitches() {
        openSettingsTab()
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<8 where !codec.buttons["AAC-ELD"].isHittable { scroll.swipeUp() }
        XCTAssertTrue(app.staticTexts["transmitCodecLabel"].exists)
        XCTAssertTrue(app.staticTexts["rtcAudioSampleRateLabel"].exists)
        codec.buttons["AAC-ELD"].tap()
        let format = app.segmentedControls.containing(.button, identifier: "48 kHz").firstMatch
        for (sampleRate, rates) in [("48 kHz", [32, 48, 64, 80, 96, 112, 128]), ("24 kHz", [16, 32, 48, 64]), ("16 kHz", [48])] {
            format.buttons[sampleRate].tap()
            for otherCodec in ["PCM 16-bit", "Opus", "PCM 16-bit"] {
                codec.buttons[otherCodec].tap()
                codec.buttons["AAC-ELD"].tap()
                let bitrate = app.buttons["aacELDBitRatePicker"].firstMatch
                XCTAssertTrue(bitrate.waitForExistence(timeout: 3))
                bitrate.tap()
                attachScreen("AAC menu \(sampleRate) after \(otherCodec)")
                func label(_ rate: Int) -> String {
                    let lowerQuality = (sampleRate == "48 kHz" && rate == 32) || (sampleRate == "24 kHz" && rate == 16)
                    return "\(rate) kbps" + (lowerQuality ? " (Lower Quality)" : "")
                }
                for rate in [16, 32, 48, 64, 80, 96, 112, 128] {
                    XCTAssertEqual(app.buttons[label(rate)].firstMatch.exists, rates.contains(rate), "\(sampleRate): \(rate) kbps after \(otherCodec)")
                }
                let selectedRate = rates.first!
                app.buttons[label(selectedRate)].firstMatch.tap()
                XCTAssertTrue(bitrate.label.contains(label(selectedRate)) || (bitrate.value as? String)?.contains(label(selectedRate)) == true)
            }
        }
        format.buttons["48 kHz"].tap()
    }

    @MainActor
    func testOpusManualLowBandwidthChoicesSurviveFormatAndCodecChanges() {
        openSettingsTab()
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<8 where !codec.buttons["Opus"].isHittable { scroll.swipeUp() }
        codec.buttons["Opus"].tap()
        let format = app.segmentedControls.containing(.button, identifier: "48 kHz").firstMatch
        let bitrate = app.steppers["opusBitRateStepper"].firstMatch
        revealSettingsControl(bitrate)
        XCTAssertTrue(bitrate.waitForExistence(timeout: 3))
        func expectRate(_ rate: Int, lowQuality: Bool) {
            let value = bitrate.value as? String ?? ""
            XCTAssertTrue(value.contains("\(rate) kbps"), value)
            XCTAssertEqual(value.contains("Lower Quality"), lowQuality)
        }
        for sampleRate in ["48 kHz", "24 kHz", "16 kHz"] {
            format.buttons[sampleRate].tap()
            for _ in 0..<53 where !(bitrate.value as? String ?? "").contains("24 kbps") {
                bitrate.buttons["opusBitRateStepper-Decrement"].tap()
            }
            expectRate(24, lowQuality: true)
            bitrate.buttons["opusBitRateStepper-Decrement"].tap()
            expectRate(24, lowQuality: true)
            bitrate.buttons["opusBitRateStepper-Increment"].tap()
            expectRate(32, lowQuality: true)
            codec.buttons["PCM 16-bit"].tap(); codec.buttons["Opus"].tap()
            expectRate(32, lowQuality: true)
            bitrate.buttons["opusBitRateStepper-Increment"].tap()
            expectRate(48, lowQuality: false)
            XCTAssertTrue(app.staticTexts["opusLowBandwidthExplanation"].exists)
            attachScreen("Opus manual choices \(sampleRate)")
        }
        format.buttons["48 kHz"].tap()
    }

    @MainActor
    func testCallDisconnectTimersPersistIndependently() {
        openSettingsTab()
        let regular = app.buttons["callDisconnectIntervalPicker"].firstMatch
        let watch = app.buttons["watchCallDisconnectIntervalPicker"].firstMatch
        func expect(_ picker: XCUIElement, _ title: String) {
            revealSettingsControl(picker)
            XCTAssertTrue(picker.label.contains(title) || (picker.value as? String)?.contains(title) == true)
        }
        func select(_ picker: XCUIElement, _ title: String) {
            revealSettingsControl(picker)
            picker.tap()
            let option = app.buttons[title].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
            expect(picker, title)
        }
        expect(regular, "3 hours")
        expect(watch, "5 minutes")
        select(regular, "15 minutes")
        expect(watch, "5 minutes")
        select(watch, "1 minute")
        openGroupsTab(); openSettingsTab()
        expect(regular, "15 minutes")
        expect(watch, "1 minute")
        app.terminate(); app.launch(); app.activate()
        openSettingsTab()
        expect(regular, "15 minutes")
        expect(watch, "1 minute")
        attachScreen("Independent call disconnection timers")
        select(regular, "3 hours")
        select(watch, "5 minutes")
    }

    @MainActor
    func testCorruptGroupStoreRecovery() throws {
        // The compile-isolated fixture seeds the actual manifest before launch.
        // Cmd-U uses the same recovery UI and checks the resulting disk files.
        let status = app.descendants(matching: .any)["groupStorageStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["groupErrorLabel"].exists)
        app.buttons["reloadSavedGroupsButton"].tap()
        XCTAssertTrue(status.exists)
        attachScreen("Saved Groups Recovery")
        app.buttons["resetSavedGroupsButton"].tap()
        let cancel = app.alerts.buttons["cancelResetSavedGroupsButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        attachScreen("Confirm Saved Groups Reset")
        cancel.tap()
        XCTAssertTrue(status.exists)
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].isEnabled)
        app.buttons["resetSavedGroupsButton"].tap()
        app.alerts.buttons["confirmResetSavedGroupsButton"].firstMatch.tap()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["standardCreateGroupButton"].isEnabled)
        app.terminate()
        app.launchEnvironment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"] = try XCTUnwrap(app.launchEnvironment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"])
            .replacingOccurrences(of: "prepare:", with: "verify:")
        app.launch()
        XCTAssertTrue(waitForVisibleRoot(in: app), "Expected the empty manifest and exact archived corrupt bytes to pass verification")
        XCTAssertFalse(app.descendants(matching: .any)["groupStorageStatus"].exists)
        createTalkGroupAndOpenCall()
        try checkGroupDeletionCanBeExercisedFromUI()
        attachScreen("Saved Groups Recovered")
    }

    @MainActor
    func testRecoveryWorkflowInOneLaunch() throws {
        // Restore the required route through UI even if a previous run stopped
        // halfway through changing settings. Do not erase application data.
        openSettingsTab()
        let localRoute = app.switches["Local Network"].firstMatch
        revealSettingsControl(localRoute)
        if localRoute.value as? String == "0" { localRoute.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let internetRoute = app.switches["Internet"].firstMatch
        if internetRoute.value as? String == "1" { internetRoute.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        openGroupsTab()
        createTalkGroupAndOpenCall()
        try checkGroupSelectionOpensCallScreen()
        try checkManualAddRiderButtonIsNotShownInCallUI()
        try checkParticipantDeletionIsNotShownForLocalMemberOnly()
        try checkCallKeepsDiagnosticsOutOfPrimaryExperience()
        try checkMuteControlLivesWithHeaderMicrophoneMeter()
        let isolation = app.switches["Master Output Voice Isolation Effect"].firstMatch
        XCTAssertTrue(isolation.waitForExistence(timeout: 3))
        let originalIsolation = isolation.value as? String
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(isolation.value as? String, originalIsolation)
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(isolation.value as? String, originalIsolation)
        try checkVoiceActivityAndHandoverCanBeExercisedFromUI()
        for _ in 0..<3 { try checkDisconnectAndReconnectButtonsTransitionInCall() }
        attachScreen("Call")
        try checkGroupsTabReturnsFromCallToGroupDirectory()
        talkGroupRows.firstMatch.tap()
        try checkGroupDeletionCanBeExercisedFromUI()
        try checkDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup()
        try checkDiagnosticsShowRealDeviceSetupIdentifiers()
        attachScreen("Diagnostics")
        try checkTabNavigationShowsExpectedRootSections()
        try checkSettingsShowsConfigPanelsWithoutDiagnosticsRows()
        try checkAudioCheckControlsAreAvailableFromSettings()
        checkSettingsChangesPersistAcrossTabs()
        attachScreen("Settings")
    }

    #if os(iOS)
    /// Layout/localization coverage only; native recording has separate acceptance.
    @MainActor
    func testAudioCheckShowsOneStartButtonInBothLayoutsAndLanguages() {
        for (mode, japanese) in [("standard", false), ("advanced", false),
                                  ("standard", true), ("advanced", true)] {
            app.terminate()
            app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = mode
            app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)",
                                   "-AppleLocale", japanese ? "ja_JP" : "en_US"]
            app.launch()
            app.activate()
            let settings = app.tabBars.buttons[japanese ? "設定" : "Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let button = app.buttons["audioCheckButton"].firstMatch
            revealSettingsControl(button)
            XCTAssertEqual(button.label, japanese ? "5秒録音して再生" : "Record 5s and Play")
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(app.buttons.matching(identifier: "audioCheckButton").count, 1)
            XCTAssertFalse(app.buttons["stopAudioCheckButton"].exists)
            XCTAssertFalse(app.buttons[japanese ? "音声チェックを停止" : "Stop Audio Check"].exists)
            attachScreen("Single recording control \(mode) \(japanese ? "Japanese" : "English")")
        }
    }

    @MainActor
    func testPhoneAudioCheckRecordsAndPlaysFromSettings() {
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Microphone access") { alert in
            guard alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'microphone'")).firstMatch.exists else { return false }
            let allow = alert.buttons["OK"].firstMatch.exists ? alert.buttons["OK"].firstMatch : alert.buttons["Allow"].firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }
        openSettingsTab()
        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let candidates = [app.buttons["audioCheckButton"].firstMatch,
                          app.descendants(matching: .any)["audioCheckButton"].firstMatch,
                          app.buttons["Record 5s and Play"].firstMatch]
        let names = ["button/identifier", "any/identifier", "button/label"]
        func observe(_ name: String) {
            var observations = ["viewport=\(scroll.exists ? String(describing: scroll.frame) : "unknown")"]
            for (name, element) in zip(names, candidates) {
                if element.exists {
                    observations.append("\(name): exists=true enabled=\(element.isEnabled) hittable=\(element.isHittable) frame=\(element.frame) label=\(element.label)")
                } else {
                    observations.append("\(name): exists=false enabled=unknown hittable=unknown frame=unknown label=unknown")
                }
            }
            for identifier in ["audioCheckStatusLabel", "audioCheckPhaseLabel", "liveAudioStateLabel"] {
                let element = app.descendants(matching: .any)[identifier].firstMatch
                observations.append(element.exists ? "\(identifier): label=\(element.label) value=\(element.value ?? "unknown")" : "\(identifier): unknown")
            }
            let details = XCTAttachment(string: observations.joined(separator: "\n") + "\n" + app.debugDescription)
            details.name = name
            details.lifetime = .keepAlways
            add(details)
        }
        observe("Audio Check before section navigation")
        revealSettingsControl(candidates[0])
        observe("Audio Check after section navigation")
        let button = candidates.first { $0.exists && $0.isHittable && $0.isEnabled }
        guard let button else { XCTFail("Audio Check button unavailable after bounded observation"); return }
        let phase = app.staticTexts["audioCheckPhaseLabel"]
        let status = app.staticTexts["audioCheckStatusLabel"]
        let input = app.descendants(matching: .any)["audioCheckInputSource"].firstMatch
        let output = app.descendants(matching: .any)["audioCheckOutputDestination"].firstMatch
        let inputMeter = app.descendants(matching: .any)["audioCheckInputMeter"].firstMatch
        let outputMeter = app.descendants(matching: .any)["audioCheckOutputMeter"].firstMatch
        for cycle in 1...2 {
            button.tap()
            if XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.waitForExistence(timeout: 2) { app.tap() }
            for expected in ["Recording", "Playing Back", "Audio Check Complete"] {
                let predicate = NSPredicate(format: "label == %@ OR label == %@", expected, "Audio Check Failed")
                let reached = expectation(for: predicate, evaluatedWith: phase)
                let result = XCTWaiter.wait(for: [reached], timeout: 15)
                let actual = phase.exists ? phase.label : "unknown"
                let passed = result == .completed && actual == expected
                let details = "phase=\(actual) buttonValue=\(button.exists ? (button.value ?? "unknown") : "unknown") status=\(status.exists ? status.label : "unknown") input=\(input.exists ? input.label : "unknown") \(input.exists ? (input.value ?? "") : "") output=\(output.exists ? output.label : "unknown") \(output.exists ? (output.value ?? "") : "") inputMeter=\(inputMeter.exists ? (inputMeter.value ?? "") : "unknown") outputMeter=\(outputMeter.exists ? (outputMeter.value ?? "") : "unknown")" + (passed ? "" : "\n" + app.debugDescription)
                let attachment = XCTAttachment(string: details)
                attachment.name = "Audio Check cycle \(cycle) \(expected)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(passed, "Expected \(expected): \(details)")
            }
            if cycle == 1 {
                button.tap()
                let recording = expectation(for: NSPredicate(format: "label == %@", "Recording"), evaluatedWith: phase)
                XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 5), .completed)
                XCTAssertEqual(button.label, "Stop Audio Check")
                button.tap()
                let stopped = expectation(for: NSPredicate(format: "label == %@", "Audio Check Idle"), evaluatedWith: phase)
                XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
                XCTAssertEqual(button.label, "Record 5s and Play")
                XCTAssertTrue(button.isEnabled)
            }
        }
    }
    #endif

    @MainActor
    func testInternetCredentialValidationKeepsTabsUsable() {
        #if os(iOS)
        app.open(URL(string: "rideintercom://join?token=invalid")!)
        XCTAssertTrue(app.descendants(matching: .any)["groupErrorLabel"].firstMatch.waitForExistence(timeout: 5))
        #endif
        checkInternetSettingsRejectUnsecuredURL()
        openGroupsTab()
        openSettingsTab()
        revealSettingsControl(app.buttons["configureInternetConnection"])
        let internet = app.switches["Internet"].firstMatch
        revealSettingsControl(internet)
        if internet.value as? String == "0" { internet.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let local = app.switches["Local Network"].firstMatch
        let original = local.value as? String
        if original == "1" { local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertEqual(local.value as? String, "0")
        // Internet-only uses the same controls, even before credentials are configured.
        openGroupsTab()
        createTalkGroupAndOpenCall()
        XCTAssertTrue(app.sliders["masterOutputSlider"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].exists)
        XCTAssertFalse(app.staticTexts["Native audio — meter unavailable"].exists)
        attachScreen("Internet Shared Audio Controls")
        openSettingsTab()
        revealSettingsControl(local)
        if original == "1" { local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertEqual(local.value as? String, original)
    }

    @MainActor
    func testAdaptivePipelineStateIsReadableWithoutColor() {
        openDiagnosticsTab()
        selectDiagnosticsPage("TX")
        let row = app.descendants(matching: .any)["pipeline-session-step"].firstMatch
        for _ in 0..<30 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(row.label.contains("Session"))
        let value = row.value as? String ?? ""
        XCTAssertTrue(["Idle, ", "Waiting, ", "Passing, ", "Blocked, "].contains { value.hasPrefix($0) }, value)
        XCTAssertGreaterThan(value.split(separator: ",", maxSplits: 1).last?.count ?? 0, 0)
        attachScreen("Pipeline state at accessibility text size")
    }

    @MainActor
    func testAdaptiveDiagnosticsAndConfigurationRemainReachable() {
        openDiagnosticsTab()
        selectDiagnosticsPage("Applied")
        let status = app.staticTexts["internetServiceCheckStatus"]
        for _ in 0..<8 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.exists)
        XCTAssertTrue(app.buttons["checkInternetService"].exists)
        XCTAssertFalse(app.buttons["checkInternetService"].isEnabled)
        selectDiagnosticsPage("Network")
        let network = app.staticTexts["networkDiagnosticsSummary"]
        XCTAssertTrue(network.waitForExistence(timeout: 3))
        XCTAssertTrue(network.isHittable, network.debugDescription)
        XCTAssertTrue(network.label.contains("Not measured"))
        attachScreen("Diagnostics Large Text Dark")
        openSettingsTab()
        let configure = app.buttons["configureInternetConnection"]
        revealSettingsControl(configure)
        configure.tap()
        XCTAssertTrue(app.textFields["internetWorkerURL"].waitForExistence(timeout: 3))
        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.app.frame.width > self.app.frame.height && self.app.buttons["closeInternetConnection"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        #endif
        XCTAssertTrue(app.buttons["closeInternetConnection"].waitForExistence(timeout: 3))
        let save = app.buttons["saveInternetConnection"]
        let form = app.collectionViews.containing(.textField, identifier: "internetWorkerURL").firstMatch
        XCTAssertTrue(form.exists)
        for _ in 0..<20 where !save.exists || save.frame.maxY > app.frame.maxY - 20 { form.swipeUp() }
        XCTAssertTrue(save.exists)
        attachScreen("Internet Settings Landscape Large Text")
        XCTAssertLessThanOrEqual(save.frame.maxY, app.frame.maxY - 20)
        app.buttons["closeInternetConnection"].tap()
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        openGroupsTab()
        XCTAssertTrue(waitForVisibleRoot(in: app))
    }

    private func openInternetSettings() {
        openSettingsTab()
        let configure = app.buttons["configureInternetConnection"]
        revealSettingsControl(configure)
        XCTAssertTrue(configure.isHittable)
        configure.tap()
    }

    private func checkInternetSettingsRejectUnsecuredURL() {
        openInternetSettings()
        let url = app.textFields["internetWorkerURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 3))
        url.tap(); url.typeText("http://example.com")
        let token = app.secureTextFields["internetDeviceToken"]
        let fixtureToken = "invalid-test-token"
        token.tap(); token.typeText(fixtureToken)
        let save = app.buttons["saveInternetConnection"]
        save.tap()
        XCTAssertTrue(app.staticTexts["Could not save. Check the HTTPS URL, device token, and Keychain access."].waitForExistence(timeout: 3))
        #if os(iOS)
        // The rejected fixture is not a password to offer to the system store.
        token.tap()
        token.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fixtureToken.count))
        #endif
        app.buttons["closeInternetConnection"].tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
    }

    private func checkSettingsChangesPersistAcrossTabs() {
        openSettingsTab()
        attachScreen("Settings before edits")
        let local = app.switches["Local Network"].firstMatch
        let internet = app.switches["Internet"].firstMatch
        revealSettingsControl(local)
        revealSettingsControl(internet)
        if internet.value as? String == "0" { internet.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let original = local.value as? String
        local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(local.value as? String, original)
        XCTAssertFalse(internet.isEnabled) // The remaining route cannot be disabled.
        openGroupsTab()
        openSettingsTab()
        XCTAssertNotEqual(local.value as? String, original)
        local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(local.value as? String, original)
        let isolation = revealTransmitIsolationToggle()
        XCTAssertTrue(isolation.waitForExistence(timeout: 3))
        let originalIsolation = isolation.value as? String
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(isolation.value as? String, originalIsolation)
        openGroupsTab()
        openSettingsTab()
        let retainedIsolation = revealTransmitIsolationToggle()
        XCTAssertNotEqual(retainedIsolation.value as? String, originalIsolation)
        retainedIsolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(retainedIsolation.value as? String, originalIsolation)
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<6 where !codec.buttons["Opus"].isHittable {
            app.descendants(matching: .any)["settingsScrollView"].firstMatch.swipeUp()
        }
        codec.buttons["Opus"].tap()
        XCTAssertTrue(codec.buttons["Opus"].isSelected)
        codec.buttons["PCM 16-bit"].tap()
        XCTAssertTrue(codec.buttons["PCM 16-bit"].isSelected)
    }

    private func revealTransmitIsolationToggle() -> XCUIElement {
        let toggle = app.switches["Transmit Voice Isolation Effect"].firstMatch
        revealSettingsControl(toggle)
        return toggle
    }

    private func attachScreen(_ name: String) {
        #if os(iOS)
        // App-scoped screenshots can crop a rotated sheet using portrait bounds.
        // This is the dedicated test Simulator, so capture its complete screen.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    private func checkGroupSelectionOpensCallScreen() throws {

        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["localMicrophonePanel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Unmuted"].exists)
        XCTAssertTrue(app.staticTexts["callPresenceLabel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["routeLabel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["localMicrophoneMuteButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mute Output"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    private func checkManualAddRiderButtonIsNotShownInCallUI() throws {

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
    }

    @MainActor
    private func checkMuteControlLivesWithHeaderMicrophoneMeter() throws {

        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].waitForExistence(timeout: 3))
        let muteButton = app.buttons["localMicrophoneMuteButton"]
        XCTAssertTrue(muteButton.waitForExistence(timeout: 3))
        muteButton.tap()
        XCTAssertTrue(app.staticTexts["Muted"].waitForExistence(timeout: 2))
    }

    @MainActor
    private func checkParticipantDeletionIsNotShownForLocalMemberOnly() throws {

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertFalse(app.buttons["removeParticipantButton0"].exists)
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
    }

    @MainActor
    private func checkDiagnosticsShowRealDeviceSetupIdentifiers() throws {
        showEmptyDiagnostics()
        selectDiagnosticsPage("Network")
        XCTAssertTrue(app.staticTexts["networkDiagnosticsSummary"].waitForExistence(timeout: 3))
        selectDiagnosticsPage("TX")
        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].exists)
        let mixer = app.descendants(matching: .any)["pipeline-mixer-step"].firstMatch
        XCTAssertTrue(mixer.exists)
        mixer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-effects-step"].waitForExistence(timeout: 3))
        selectDiagnosticsPage("RX")
        XCTAssertTrue(app.descendants(matching: .any)["liveReceivePipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["receive-pipeline-mix-step"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receive-mix-topology"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receive-pipeline-output-step"].exists)
        selectDiagnosticsPage("Overview")
        revealDiagnosticOverview()
        XCTAssertTrue(app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioIOPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioCheckPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    private func checkAudioCheckControlsAreAvailableFromSettings() throws {
        openSettingsTab()

        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioIOPanel"].firstMatch.waitForExistence(timeout: 3))

        revealAudioCheckControlsIfNeeded()

        XCTAssertTrue(audioCheckButtonElement().waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckPanel"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    private func checkVoiceActivityAndHandoverCanBeExercisedFromUI() throws {

        XCTAssertTrue(app.buttons["disconnectButton"].exists)
        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Simulate Handover"].exists)
        XCTAssertFalse(app.staticTexts["Silent"].exists)
    }

    @MainActor
    private func checkCallKeepsDiagnosticsOutOfPrimaryExperience() throws {

        XCTAssertFalse(app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["transportDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["groupHashDebugSummaryLabel"].exists)
        XCTAssertFalse(app.staticTexts["Live TX Pipeline"].exists)
    }

    @MainActor
    private func checkGroupDeletionCanBeExercisedFromUI() throws {
        openGroupsTab()

        let groupRows = talkGroupRows
        let initialCount = groupRows.count
        let groupRow = groupRows.firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 3))
        groupRow.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 2))
        app.buttons["Delete"].tap()
        XCTAssertLessThan(talkGroupRows.count, initialCount)
    }

    @MainActor
    private func checkDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup() throws {
        showEmptyDiagnostics()
        selectDiagnosticsPage("TX")
        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-input-step"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pipeline-effect-stage-vad-gate"].exists) // No invented idle Mixer effects.
        selectDiagnosticsPage("RX")
        XCTAssertTrue(app.descendants(matching: .any)["liveReceivePipelineView"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func checkTabNavigationShowsExpectedRootSections() throws {
        openGroupsTab()
        XCTAssertTrue(app.descendants(matching: .any)["standardGroupsList"].firstMatch.waitForExistence(timeout: 3))

        openDiagnosticsTab()
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch.waitForExistence(timeout: 3))
        selectDiagnosticsPage("TX")
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-input-step"].firstMatch.waitForExistence(timeout: 3))

        openSettingsTab()
        XCTAssertTrue(app.descendants(matching: .any)["settingsScrollView"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "audioSessionPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioSessionPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        XCTAssertTrue(app.descendants(matching: .any)["transmitCodecPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "voiceActivityPanel")
        XCTAssertTrue(app.descendants(matching: .any)["voiceActivityPanel"].firstMatch.waitForExistence(timeout: 3))

        openGroupsTab()
        XCTAssertTrue(waitForVisibleRoot(in: app))
    }

    @MainActor
    private func checkGroupsTabReturnsFromCallToGroupDirectory() throws {
        let call = app.descendants(matching: .any)["callScreen"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 3))
        XCTAssertFalse(call.buttons["showGroupsButton"].exists)
        XCTAssertFalse(call.buttons["createGroupButton"].exists)
        XCTAssertFalse(call.buttons["standardCreateGroupButton"].exists)
        openGroupsTab()
        XCTAssertTrue(app.descendants(matching: .any)["standardGroupsList"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["standardCreateGroupButton"].firstMatch.exists)
    }

    @MainActor
    private func checkDisconnectAndReconnectButtonsTransitionInCall() throws {

        let disconnectButton = app.buttons["disconnectButton"].firstMatch
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 3))
        disconnectButton.tap()

        // Ending closes the call; choosing the group again reconnects at once.
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].firstMatch.waitForNonExistence(timeout: 5))
        openGroupsTab()
        let group = talkGroupRows.firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        group.tap()

        XCTAssertTrue(app.buttons["disconnectButton"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func checkSettingsShowsConfigPanelsWithoutDiagnosticsRows() throws {
        openSettingsTab()

        revealSettingsPanelIfNeeded(identifier: "audioSessionPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioSessionPanel"].firstMatch.waitForExistence(timeout: 3))
        let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "mode uses")).firstMatch
        revealSettingsControl(explanation, fullyVisible: false)
        XCTAssertTrue(explanation.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioSessionProfileStatus"].firstMatch.exists)
        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioIOPanel"].firstMatch.waitForExistence(timeout: 3))
        revealAudioCheckControlsIfNeeded()
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        XCTAssertTrue(app.descendants(matching: .any)["transmitCodecPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["transmitCodecStatus"].firstMatch.exists)
        revealSettingsPanelIfNeeded(identifier: "voiceActivityPanel")
        XCTAssertTrue(app.descendants(matching: .any)["voiceActivityPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["vadAnalysisStatus"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioIOApplyStateLabel"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioInputProcessingSummaryLabel"].firstMatch.exists)
    }

    private func assertAdvancedCallHasNoManagementControls() {
        let call = app.descendants(matching: .any)["callScreen"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 3))
        // The lists stay underneath the call sheet; only the call itself must not offer management.
        for identifier in ["inviteButton", "addSavedUsersButton", "showGroupsButton", "createGroupButton",
                           "standardCreateGroupButton", "editParticipantNameButton0", "removeParticipantButton0"] {
            XCTAssertFalse(call.buttons[identifier].exists, "Management control remains in Advanced Call: \(identifier)")
        }
        XCTAssertFalse(call.buttons["Edit Name"].exists)
        XCTAssertFalse(call.buttons.containing(.staticText, identifier: "participantName0").firstMatch.exists)
        XCTAssertFalse(call.buttons["Delete"].exists)
    }

    /// Group Settings opens from the row's swipe (or context menu); the row tap only connects.
    private func openTalkGroupManagement() {
        openGroupsTab()
        openRowSettings(talkGroupRows.firstMatch, "Group Settings", view: "groupSettingsView")
    }

    private func openRowSettings(_ row: XCUIElement, _ title: String, view: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        let settings = app.buttons[title].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)[view].firstMatch.waitForExistence(timeout: 3))
    }

    private func copyManagementInvitation(identifier: String = "groupSettingsInviteButton", view: String = "groupSettingsView") {
        let invite = app.buttons[identifier].firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 3))
        invite.tap()
        let copy = app.cells.matching(NSPredicate(format: "label == 'Copy' OR label == 'Copy Link'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Native sharing offers the invitation URL")
        attachScreen("Directory management invitation native share sheet")
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[view].firstMatch.exists)
        XCTAssertTrue(invite.exists)
    }

    private func closeManagementAndReturnToCall() {
        let close = ["closeGroupSettingsButton", "closeUserSettingsButton"].map { app.buttons[$0].firstMatch }
            .first { $0.exists } ?? app.buttons["closeGroupSettingsButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        app.openCurrentCall()
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].firstMatch.waitForExistence(timeout: 3))
    }

    private var talkGroupRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
            .containing(.staticText, identifier: "Talk Group")
    }

    private func createTalkGroupAndOpenCall() {
        openGroupsTab()
        removeExistingTalkGroups()
        let createButton = app.buttons["standardCreateGroupButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + "Talk Group")
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))
    }

    private func showEmptyDiagnostics() {
        openGroupsTab()
        removeExistingTalkGroups()
        openDiagnosticsTab()
    }

    private func openDirectoryTab(_ title: String, identifier: String, root: String) {
        app.closeCallIfOpen()
        if app.descendants(matching: .any)[root].firstMatch.exists { return }
        let identified = app.buttons[identifier].firstMatch
        if identified.exists { identified.tap() }
        else if app.radioButtons[identifier].firstMatch.exists { app.radioButtons[identifier].firstMatch.tap() }
        else {
            let button = app.tabBars.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)[root].firstMatch.waitForExistence(timeout: 3))
    }

    private func openGroupsTab() {
        openDirectoryTab("Groups", identifier: "groupsTab", root: "standardGroupsList")
    }

    private func openUsersTab() {
        openDirectoryTab("Users", identifier: "usersTab", root: "standardUsersList")
    }

    private func openDiagnosticsTab() {
        app.closeCallIfOpen()
        if app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch.exists { return }
        if app.tabBars.buttons["Diagnostics"].firstMatch.exists { app.tabBars.buttons["Diagnostics"].firstMatch.tap() }
        else if app.radioButtons["diagnosticsTab"].firstMatch.exists { app.radioButtons["diagnosticsTab"].firstMatch.tap() }
        else if app.buttons["diagnosticsTab"].firstMatch.exists { app.buttons["diagnosticsTab"].firstMatch.tap() }
        else { app.buttons["Diagnostics"].firstMatch.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch.waitForExistence(timeout: 3))
    }

    private func selectDiagnosticsPage(_ title: String) {
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.isHittable, picker.debugDescription)
        picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        choice.tap()
    }

    private func openSettingsTab() {
        app.closeCallIfOpen()
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        if !scroll.exists {
            #if os(iOS)
            let identified = app.tabBars.buttons["settingsTab"].firstMatch
            let button = identified.exists ? identified : app.tabBars.buttons["Settings"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
            #else
            let radio = app.radioButtons["settingsTab"].firstMatch
            if radio.exists { radio.tap() }
            else {
                let identified = app.buttons["settingsTab"].firstMatch
                let button = identified.exists ? identified : app.tabBars.buttons["Settings"].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 3))
                button.tap()
            }
            #endif
        }
        guard scroll.waitForExistence(timeout: 5) else {
            XCTFail("Settings tab did not open"); return
        }
    }

    private func selectSettingsLayout(_ title: String) {
        XCTAssertTrue(title == "Standard" || title == "Advanced", "Unknown layout: \(title)")
        let advanced = app.tabBars.buttons["Diagnostics"].exists || app.buttons["diagnosticsTab"].exists
        if !advanced {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealSettingsControl(more)
            more.tap()
        }
        let picker = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3)); picker.tap()
        let choice = app.buttons[title].firstMatch
        if choice.exists { choice.tap() } else {
            let menu = app.menuItems[title].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 3)); menu.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["settingsScrollView"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Settings is a lazy Form. Navigate to the requested row rather than assuming
    /// every target is near Local Network, or a fixed number of screens from the top.
    private func revealSettingsControl(_ target: XCUIElement, fullyVisible: Bool = true,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), file: file, line: line)
        for attempt in 0..<36 {
            let viewport = scroll.frame.intersection(app.frame).insetBy(dx: 0, dy: 4)
            if target.exists && !target.frame.isEmpty
                && (fullyVisible ? target.isHittable && viewport.contains(target.frame) : viewport.intersects(target.frame)) { return }
            let hasFrame = target.exists && !target.frame.isEmpty
            let down = hasFrame ? target.frame.midY < viewport.midY : (attempt < 6 || attempt >= 30)
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Settings control did not become reachable: \(target.debugDescription)", file: file, line: line)
    }

    private func revealDiagnosticOverview() {
        let scroll = app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch
        for _ in 0..<8 {
            if app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists { return }
            scroll.swipeUp()
        }
    }

    private func revealAudioCheckControlsIfNeeded() {
        revealSettingsControl(audioCheckButtonElement())
    }

    private func revealSettingsPanelIfNeeded(identifier: String) {
        openSettingsTab()
        let panel = app.descendants(matching: .any)[identifier].firstMatch
        revealSettingsControl(panel, fullyVisible: false)
    }

    private func audioCheckButtonElement() -> XCUIElement {
        let byIdentifier = app.descendants(matching: .any)["audioCheckButton"].firstMatch
        if byIdentifier.exists {
            return byIdentifier
        }

        let byLabel = app.buttons["Record 5s and Play"].firstMatch
        if byLabel.exists {
            return byLabel
        }

        return byIdentifier
    }

    private func removeExistingTalkGroups() {
        openGroupsTab()

        let groupRows = talkGroupRows
        while groupRows.count > 0 {
            let countBeforeDelete = groupRows.count
            let groupRow = groupRows.firstMatch
            guard groupRow.waitForExistence(timeout: 1) else { return }

            groupRow.swipeLeft()
            let deleteButton = app.buttons["Delete"].firstMatch
            XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
            deleteButton.tap()

            XCTAssertLessThan(talkGroupRows.count, countBeforeDelete)
        }
    }

    /// Saved users persist on the reused simulator; start each test from an empty Users list
    /// so queries for "the saved user" find the one this test invited.
    private func removeExistingSavedUsers() {
        openUsersTab()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
        while rows.count > 0 {
            let countBeforeDelete = rows.count
            let row = rows.firstMatch
            guard row.waitForExistence(timeout: 1) else { return }
            row.swipeLeft()
            let deleteButton = app.buttons["Delete"].firstMatch
            XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
            deleteButton.tap()
            XCTAssertLessThan(rows.count, countBeforeDelete)
        }
    }

    private func waitForVisibleRoot(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3)
            || app.descendants(matching: .any)["callScreen"].firstMatch.exists
            || app.descendants(matching: .any)["standardGroupsList"].firstMatch.exists
            || app.descendants(matching: .any)["standardCallScreen"].firstMatch.exists
    }
}
