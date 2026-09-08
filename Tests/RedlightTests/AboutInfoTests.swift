import Foundation
import Testing
@testable import Redlight

@Suite struct AboutInfoTests {
    @Test func creditsNameTheAuthorAndPublicRepo() {
        #expect(AboutInfo.name == "Redlight")
        #expect(AboutInfo.author == "Andrew Fitzgerald")
        #expect(AboutInfo.repositoryURL.absoluteString == "https://github.com/andrewfitz/redlight")
        #expect(AboutInfo.repositoryDisplay == "github.com/andrewfitz/redlight")
    }

    @Test func versionUsesShortStringAndOmitsDuplicateBuild() {
        #expect(AboutInfo.version(shortVersion: "1.2", build: "1.2") == "1.2")
        #expect(AboutInfo.version(shortVersion: "1.2", build: "14") == "1.2 (14)")
    }

    @Test func versionFallsBackWhenBundleKeysAreMissing() {
        #expect(AboutInfo.version(shortVersion: nil, build: nil) == "1.0")
        #expect(AboutInfo.version(shortVersion: "", build: "") == "1.0")
    }
}
