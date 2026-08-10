import Testing
@testable import FWBSocial

@Suite("Scaffold sanity")
struct FWBSocialTests {
    @Test("FWBConfig has a non-empty dev base URL")
    func configBaseURL() {
        #expect(!FWBConfig.baseURL.isEmpty)
    }

    @Test("APIClient.path drops nil query values")
    func pathQueryHelper() {
        let path = APIClient.path("/api/things", query: ["a": "1", "b": nil])
        #expect(path == "/api/things?a=1")
    }
}
