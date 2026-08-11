import Foundation
import Testing
@testable import FWBSocial

@Suite("Scaffold sanity")
struct FWBSocialTests {
    @Test("FWBConfig has a non-empty base URL")
    func configBaseURL() {
        #expect(!FWBConfig.baseURL.isEmpty)
    }

    @Test("APIClient.path drops nil query values")
    func pathQueryHelper() {
        let path = APIClient.path("/api/things", query: ["a": "1", "b": nil])
        #expect(path == "/api/things?a=1")
    }
}

// MARK: - Wire contract
//
// The mirror of fwb-server's `WireContractTests`. That suite pins the keys the
// server *emits*; this one pins that the client can *read* them. Both sides use
// `.convertFromSnakeCase`, and the trap they exist for is specific: Foundation's
// conversion is not symmetric across consecutive capitals, so a server property
// named `notifyDM` emits `notify_dm` and decodes back as `notifyDm` — a field
// that serialises perfectly and silently fails to decode on this side.
//
// A fixture written by hand from the server's pinned key list is the only thing
// that catches a rename before a member does.

@Suite("Wire contract")
struct WireContractTests {

    /// Byte-identical in strategy to the server's configured encoder — the exact
    /// key list is `WireContractTests.testUserResponseEmitsTheExpectedSnakeCaseKeys`
    /// in fwb-server.
    private static let userJSON = """
    {
      "id": "0E2F5F1E-6C1C-4B7A-9C3E-2C5B0A9D1F44",
      "email": "member@example.com",
      "display_name": "Test Member",
      "username": "test_member",
      "avatar_url": "https://example.invalid/avatar.jpg",
      "bio": "hello",
      "friend_code": "ABCD2345",
      "email_verified": true,
      "has_password": true,
      "has_apple_sign_in": true,
      "vetting_state": "vetted",
      "vetting_source": "event_checkin",
      "vetted_at": "2026-02-01T00:00:00Z",
      "inbox_policy": "friends_only",
      "is_discoverable": true,
      "hide_message_previews": false,
      "luma_email": "luma@example.com",
      "luma_email_verified": true,
      "is_admin": false,
      "is_moderator": true,
      "notify_announcements": true,
      "notify_dm": true,
      "notify_friend_requests": false,
      "notify_channel_posts": true,
      "timezone": "America/Los_Angeles",
      "last_active_at": "2026-02-01T00:00:01Z",
      "created_at": "2026-02-01T00:00:02Z",
      "updated_at": "2026-02-01T00:00:03Z"
    }
    """

    @Test("AuthUser decodes every key the server pins")
    func authUserDecodes() throws {
        let user = try FWBJSON.decoder.decode(AuthUser.self, from: Data(Self.userJSON.utf8))

        // The two fields that actually broke on the server side, asserted by
        // name so a regression reads as itself.
        #expect(user.notifyDm == true)
        #expect(user.avatarUrl == "https://example.invalid/avatar.jpg")

        #expect(user.email == "member@example.com")
        #expect(user.displayName == "Test Member")
        #expect(user.isVetted)
        #expect(user.isModerator)
        #expect(user.isAdmin == false)
        #expect(user.hideMessagePreviews == false)
        #expect(user.notifyFriendRequests == false)
        #expect(user.lumaEmailVerified == true)
        #expect(user.friendCode == "ABCD2345")
        #expect(user.vettedAt != nil)
    }

    @Test("AuthResponse's access_token / refresh_token round-trip")
    func authResponseDecodes() throws {
        let json = """
        { "user": \(Self.userJSON), "access_token": "abc", "refresh_token": "def" }
        """
        let response = try FWBJSON.decoder.decode(AuthTokenResponse.self, from: Data(json.utf8))
        #expect(response.resolvedAccessToken == "abc")
        #expect(response.refreshToken == "def")
        #expect(response.user?.displayName == "Test Member")
    }

    /// A member who has never been vetted has nulls where an established member
    /// has values. Typing any of those non-optional would take the whole
    /// sign-in response down.
    @Test("AuthUser survives a brand-new account's nulls")
    func authUserTolerAtesNulls() throws {
        let json = """
        {
          "id": "0E2F5F1E-6C1C-4B7A-9C3E-2C5B0A9D1F44",
          "email": "new@example.com",
          "display_name": "New Member",
          "username": null,
          "avatar_url": null,
          "bio": null,
          "friend_code": null,
          "email_verified": false,
          "vetting_state": "pending",
          "vetting_source": null,
          "vetted_at": null,
          "is_admin": false,
          "is_moderator": false
        }
        """
        let user = try FWBJSON.decoder.decode(AuthUser.self, from: Data(json.utf8))
        #expect(user.isVetted == false)
        #expect(user.vettingLabel == "Pending")
        #expect(user.avatarUrl == nil)
    }
}

// MARK: - Pagination envelope

@Suite("Paged response")
struct PagedResponseTests {

    @Test("Decodes Vapor's { items, metadata } page")
    func decodesEnvelope() throws {
        let json = """
        { "items": [{ "id": "a", "title": "One" }],
          "metadata": { "page": 1, "per": 20, "total": 1 } }
        """
        let page = try FWBJSON.decoder.decode(PagedResponse<Announcement>.self, from: Data(json.utf8))
        #expect(page.items.count == 1)
        #expect(page.items.first?.displayTitle == "One")
        #expect(page.metadata?.total == 1)
    }

    /// A cacheable public collection route is often written to return a bare
    /// array. Accepting it means a reasonable server-side choice can't become a
    /// client outage.
    @Test("Decodes a bare array as a single complete page")
    func decodesBareArray() throws {
        let json = """
        [{ "id": "a", "title": "One" }, { "id": "b", "title": "Two" }]
        """
        let page = try FWBJSON.decoder.decode(PagedResponse<Announcement>.self, from: Data(json.utf8))
        #expect(page.items.count == 2)
        #expect(page.metadata == nil)
    }

    @Test("Decodes an empty envelope without throwing")
    func decodesEmpty() throws {
        let page = try FWBJSON.decoder.decode(PagedResponse<Announcement>.self, from: Data("{}".utf8))
        #expect(page.items.isEmpty)
    }
}

// MARK: - Announcement

@Suite("Announcement decoding")
struct AnnouncementTests {

    @Test("Reads the plan's §2.2 column shape")
    func decodesFullRow() throws {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "title": "Doors at eight",
          "body": "See you **there**.",
          "visibility": "vetted",
          "status": "published",
          "is_pinned": true,
          "published_at": "2026-08-01T19:00:00Z",
          "created_at": "2026-07-31T19:00:00Z",
          "author": { "id": "abc", "display_name": "Commissioner", "avatar_url": null }
        }
        """
        let announcement = try FWBJSON.decoder.decode(Announcement.self, from: Data(json.utf8))
        #expect(announcement.pinned)
        #expect(announcement.isVettedOnly)
        #expect(announcement.isPublished)
        #expect(announcement.authorName == "Commissioner")
        #expect(announcement.timestamp != nil)
        // Unread until the authenticated feed says otherwise.
        #expect(announcement.isUnread)
    }

    /// Only `id` is guaranteed. Everything else has to survive being absent,
    /// because the server side is still being written.
    @Test("Survives a row with nothing but an id")
    func decodesMinimalRow() throws {
        let announcement = try FWBJSON.decoder.decode(
            Announcement.self, from: Data(#"{ "id": "x" }"#.utf8))
        #expect(announcement.displayTitle == "Untitled")
        #expect(announcement.displayBody.isEmpty)
        #expect(announcement.pinned == false)
        // No `status` means published — a draft is explicit or it isn't a draft.
        #expect(announcement.isPublished)
    }

    @Test("A flat author_display_name is read too")
    func decodesFlatAuthor() throws {
        let json = #"{ "id": "x", "author_display_name": "Someone" }"#
        let announcement = try FWBJSON.decoder.decode(Announcement.self, from: Data(json.utf8))
        #expect(announcement.authorName == "Someone")
    }
}

// MARK: - Age gate
//
// The verdict logic, tested away from the system sheet. `AgeRangeService.Response`
// can't be constructed in a test (its cases carry an SDK struct with no public
// initialiser), so what's exercised here is the part that encodes the policy:
// the error path and the unavailable attestation.

@Suite("Age gate")
struct AgeGateTests {

    @Test("A failed request is 'unavailable', never 'under age'")
    func errorIsNotAVerdict() {
        struct Boom: Error {}
        let outcome = AgeGateService.evaluate(error: Boom())
        guard case .unavailable = outcome else {
            Issue.record("a thrown error must not be read as an age verdict; got \(outcome)")
            return
        }
    }

    @Test("The unavailable attestation records that the gate did not run")
    func unavailableAttestationIsHonest() {
        let attestation = AgeGateService.unavailableAttestation()
        #expect(attestation.source == "unavailable")
        // The whole point: these accounts are findable later precisely because
        // the attestation does NOT claim the threshold was met.
        #expect(attestation.meetsThreshold == false)
        #expect(attestation.threshold == FWBConfig.minimumAge)
        #expect(attestation.lowerBound == nil)
    }

    @Test("The gate asks about 18")
    func thresholdIsEighteen() {
        #expect(FWBConfig.minimumAge == 18)
    }
}
