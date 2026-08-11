# Phase 4 (iOS forums) — handoff

**Written:** 2026-08-10, on an interrupted session (machine disconnect).
**State: NOTHING IMPLEMENTED YET.** The session got through research only. The
working tree is clean apart from this file; no commits touched app code, no
simulator run happened, **no temp accounts were created on production** — there
is nothing to clean up on the server.

Delete this file when Phase 4 lands.

---

## DONE

Research only. The findings below are the whole value of the session — they are
recorded so the next agent does not re-derive them.

### The live server contract (read from `/Users/bobak/Documents/Xcode/fwb-server`, READ-ONLY)

Phase 4 + 5 routes are deployed at `https://api.fwb.events`. Exact registrations,
from `Sources/App/routes.swift`:

Behind `RequireVettedMember` (`vetted` group, all under `/api`):

```
GET    /api/channels
GET    /api/channels/:slug/posts
POST   /api/channels/:slug/posts
PUT    /api/channels/:slug/mute
GET    /api/posts/:id
PATCH  /api/posts/:id
DELETE /api/posts/:id
POST   /api/posts/:id/pin
POST   /api/posts/:id/lock
GET    /api/posts/:id/comments
POST   /api/posts/:id/comments
PATCH  /api/comments/:id
DELETE /api/comments/:id
PUT    /api/posts/:id/reactions        DELETE /api/posts/:id/reactions
PUT    /api/comments/:id/reactions     DELETE /api/comments/:id/reactions
```

Any authenticated member (NOT vetting-gated):

```
POST   /api/reports          (rate-limited 20 / 300s)
GET    /api/reports/mine
GET    /api/blocks
POST   /api/blocks/:userId
DELETE /api/blocks/:userId
```

Moderator tier: `GET /api/admin/reports`, `POST /api/admin/reports/:id/assign`,
`POST /api/admin/reports/:id/resolve`, `GET /api/admin/reports/:id/evidence`.
Admin tier: `GET|POST /api/admin/channels`, `PATCH /api/admin/channels/:id`,
`GET /api/admin/channels/:id/members`,
`PUT /api/admin/channels/:id/members/:userId/role`,
`GET|PUT /api/admin/moderation/blocked-terms`.

### Wire shapes — already confirmed, do not guess

`Sources/App/Modules/Forum/ForumDTOs.swift` and
`Sources/App/Modules/Moderation/ModerationDTOs.swift` are the source of truth;
`Tests/AppTests/WireContractTests.swift` pins them. Two house rules the server
enforces on itself and the client must mirror: **no explicit snake_case
`CodingKeys`** and **no consecutive capitals in a property name** (so
`avatarUrl`, not `avatarURL`). The client decoder uses `.convertFromSnakeCase`
per `FWBSocial/Services/JSONCoding.swift` — verify that against these before
writing models.

Key server-resolved permission fields (client must **never** infer permissions):

- `ChannelResponse`: `effectiveRole`, `canPost`, `canComment`, `canModerate`,
  `muted`, `postCount`, `visibility`, `isArchived`, `sfSymbol`, `accentHex`,
  `sortOrder`. Inaccessible private channels are **omitted from the list**, never
  returned with a null role.
- `PostResponse`: `isPinned`, `isLocked`, `myReaction` (caller's own reaction, so
  the reaction control renders selected state with no second request),
  `commentCount`, `reactionCount`, `status`, `removalReason`, `canEdit`,
  `canDelete`, `canModerate`, `lastActivityAt`, `editedAt`.
- `CommentResponse`: `parentCommentId` (one nesting level), `myReaction`,
  `canEdit`, `canDelete`.
- `PostFeedResponse`: `items`, `total`, `page`, `per`, `hasMore` — feed this to
  the existing `Components/PaginatedLoader.swift`.
- `ForumAuthor` **is the discovery surface** (commissioner decision 9): `id`,
  `displayName`, `username`, `avatarUrl`, `allowsFriendRequests`, `isDeleted`.
  `allowsFriendRequests` is what gates the friend-request button per-target;
  `isDeleted` means render "Deleted member" and suppress the profile tap.
  It deliberately does **not** carry `friendCode`.
- Reactions are **opaque tokens** server-side (`SetReactionRequest.reactionType`,
  a short string like `like` / `heart`). The emoji set is a client decision — no
  server deploy needed to add one.
- `CreateReportRequest`: `targetType`, `targetId`, `reason`, `details`,
  `evidence` (chat only — leave nil in Phase 4).
- Ban is a two-option flow (`BanRequest.disposition` = `delete_all_content` |
  `keep_tombstoned`, **required, no default**) — commissioner decision 7. Ban is
  admin-tier and arguably Phase 8 polish; do not silently default it.

### Repo state

- Clean, on `main`, pulled, up to date with origin at `50f55eb`.
- `FWBSocial/App/AppState.swift:60` — `nonisolated enum FWBFeatures` with
  `channels = false`. **Flipping that one constant is the whole tab change**;
  `RootTabView` needs no edit (it gates on `FWBTab.isEnabled`).
- `FWBSocial/Features/Channels/ChannelsView.swift` exists as a placeholder.
- Existing kit to build on: `Components/PaginatedLoader.swift`,
  `Components/FWBComponents.swift`, `Components/ToastCenter.swift`,
  `Services/APIClient.swift`, `Theme/Theme.swift`.

### ⚠️ Landmine found — deal with this first

`FWBSocialUITests/SmokeTests 2.swift` is an **iCloud duplicate** (untracked, not
in git). Per house rule, iCloud `" 2"` dupes break builds. Confirm it is not
picked up by the XcodeGen target glob in `project.yml` and delete it before the
first build, or the build failure will look like a code error.

---

## IN PROGRESS

Nothing. No file was edited.

---

## NOT STARTED — the entire Phase 4 scope

1. Flip `FWBFeatures.channels`; channel list with role-appropriate affordances.
2. Channel view: paginated post list, pinned posts surfaced, locked-post state.
3. Text-first post composer (**no media picker** — deferred per §8), comment
   threads, edit/delete own content, reactions via a `ReactionLikeControl`-style
   long-press fan-out with optimistic updates (port from MyStickyApp
   `Core/Extensions/ComicCardViews.swift` lines 501–636, ~135 LoC, reskin off
   `Theme/Theme.swift`).
4. Tappable author profile sheet + friend-request button gated behind a **new**
   `FWBFeatures.friendRequests = false` (ships inert; endpoint arrives Phase 6)
   **and** the target's `allowsFriendRequests`.
5. Report sheet (reason picker) on posts/comments/profiles; block from the
   profile sheet; client-side filtering of blocked authors where the API does not
   already omit them.
6. Per-channel mute toggle in the channel view (`PUT /api/channels/:slug/mute`).
7. Settings: `allow_forum_friend_requests` toggle.
8. Admin/moderator surfaces: pin/lock, delete any post/comment, minimal report
   queue (`GET /api/admin/reports` + assign/resolve). Functional, not fancy.
9. Build green + simulator smoke against production + screenshots to
   `/tmp/fwb-p4-evidence/`.

---

## Precise next action

1. `git pull`, delete the untracked `FWBSocialUITests/SmokeTests 2.swift` dupe.
2. Read `FWBSocial/Services/AnnouncementModels.swift` +
   `Services/AnnouncementsAPI.swift` — they are the established pattern for a
   feature's DTO/API pair and Phase 4's `ForumModels.swift` / `ForumAPI.swift`
   should match their shape exactly.
3. Write `Services/ForumModels.swift` mirroring the DTOs above verbatim, then
   `Services/ForumAPI.swift` over `APIClient`.
4. Only then start on views, and flip `FWBFeatures.channels` last so the tab
   never appears half-built.

Build convention: `xcodebuild`, generic iOS Simulator destination, `/tmp`
derivedData, and the `/tmp/fwb-build.lock.d` mkdir-lock — **wait on the lock,
never kill it**.

User-facing brand text is always lowercase **fwb social**.
