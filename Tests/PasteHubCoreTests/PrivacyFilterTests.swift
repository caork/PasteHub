import Foundation
import Testing
@testable import PasteHubCore

struct PrivacyFilterTests {
    @Test func allowsOrdinaryText() {
        let context = PrivacyFilter.Context(
            text: "hello from VS Code",
            sourceBundleID: "com.microsoft.VSCode",
            skipOneTimeCodes: true
        )
        #expect(PrivacyFilter.shouldCapture(context))
    }

    @Test func blocksPasswordManagers() {
        let context = PrivacyFilter.Context(
            text: "x",
            sourceBundleID: "com.1password.1password",
            skipOneTimeCodes: true
        )
        #expect(!PrivacyFilter.shouldCapture(context))
    }

    @Test func blocksSixDigitOTP() {
        #expect(PrivacyFilter.looksLikeOneTimeCode("183920"))
        let context = PrivacyFilter.Context(
            text: "183920",
            sourceBundleID: nil,
            skipOneTimeCodes: true
        )
        #expect(!PrivacyFilter.shouldCapture(context))
    }

    @Test func allowsFourDigitYear() {
        #expect(!PrivacyFilter.looksLikeOneTimeCode("2026"))
        let context = PrivacyFilter.Context(
            text: "2026",
            sourceBundleID: nil,
            skipOneTimeCodes: true
        )
        #expect(PrivacyFilter.shouldCapture(context))
    }

    @Test func blocksVerificationCodeKeyword() {
        #expect(PrivacyFilter.looksLikeOneTimeCode("验证码 183920"))
        #expect(PrivacyFilter.looksLikeOneTimeCode("Your OTP is 123456"))
    }

    @Test func skipsOTPFilterWhenDisabled() {
        let context = PrivacyFilter.Context(
            text: "183920",
            sourceBundleID: nil,
            skipOneTimeCodes: false
        )
        #expect(PrivacyFilter.shouldCapture(context))
    }

    @Test func rejectsEmptyAndHugeText() {
        let empty = PrivacyFilter.Context(text: "   ", sourceBundleID: nil, skipOneTimeCodes: true)
        #expect(!PrivacyFilter.shouldCapture(empty))

        let huge = PrivacyFilter.Context(
            text: String(repeating: "a", count: PasteHubDefaults.maxTextBytes + 1),
            sourceBundleID: nil,
            skipOneTimeCodes: true
        )
        #expect(!PrivacyFilter.shouldCapture(huge))
    }
}
