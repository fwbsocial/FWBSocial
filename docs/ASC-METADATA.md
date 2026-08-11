# App Store Connect metadata — fwb social

Everything App Store Connect asks for, written out so it can be pasted rather than
improvised at submission time. Sources: `PLAN.md` §6 (compliance), the
commissioner decisions of 2026-08-10, and the shipped app itself.

**Brand casing.** The user-facing name is always lowercase — **fwb social** — in
every field below, including the App Name. Technical identifiers (bundle id, Swift
types, the `FWBSocial` target) keep their own casing and are not user-facing.

> ## ⚠️ Blockers to clear before submitting
>
> 1. **`ITSAppUsesNonExemptEncryption` is currently `false`** (`FWBSocial/Info.plist`,
>    set from `project.yml`). This app implements end-to-end encryption of member
>    content using its own key management (X-Wing = ML-KEM-768 + X25519, AES-GCM),
>    which is materially more than the "HTTPS only" case the exemption is written
>    for. Whether it qualifies for an exemption, needs a self-classification report
>    to BIS, or needs a CCATS is a **legal determination and is not made here** —
>    the flag has deliberately been left as it is rather than flipped on a guess.
>    Get an answer before the first upload; changing it later means a new build.
> 2. **`https://legal.fwb.events/support` and `/privacy` are not deployed yet.**
>    App Review fetches both. An unreachable Support URL or Privacy Policy URL is a
>    routine rejection. `fwb-web` is a separate repo and a separate deploy.
> 3. **Screenshots currently contain placeholder artwork** in the media post (see
>    `docs/` evidence and the sweep notes). Swap in real event photography, or
>    reshoot without the media post, before uploading. Nothing in the set may be
>    suggestive — screenshots are reviewed under Guideline 2.3.
> 4. **The demo content lives on a local server.** Before review, seed the
>    equivalent content on production and confirm the reviewer credentials work
>    there (see *Review notes* below).

---

## 1. App information

| Field | Value |
|---|---|
| **App Name** (30 max) | `fwb social` |
| **Subtitle** (30 max) | `Members, events, forums, chat` (29) |
| **Bundle ID** | `events.fwb.social` |
| **Primary category** | Social Networking |
| **Secondary category** | Lifestyle |
| **Primary language** | English (U.S.) |
| **Age rating** | 18+ (see §5) |
| **Price** | Free, no in-app purchases |
| **Support URL** | `https://legal.fwb.events/support` |
| **Privacy Policy URL** | `https://legal.fwb.events/privacy` |
| **Marketing URL** | *(leave blank until the public site exists)* |
| **EULA** | Custom — hosted at `https://legal.fwb.events/terms`, version `2026-08-10`, matching `FWBConfig.agreementsVersion` |
| **Copyright** | `2026 AppTapTap` |

**Subtitle alternates**, if the primary reads too much like a feature list. All are
deliberately mundane, because the subtitle is doing disambiguation work — see §5.

- `For members: events and forums` (30)
- `Your club's private app` (23)
- `A private members' community` (28)

---

## 2. Description

> fwb social is the private app for our members. It is invitation-only: you get in
> by being part of the club, and there is no public directory, no browsing of
> members, and no search for people.
>
> **Announcements.** Everything the organisers need you to know, in one feed, with
> a notification when it matters and none when it doesn't.
>
> **Channels.** Member forums for the things that come up between events —
> planning, recommendations, the long conversations that don't fit in a group
> chat. Post with photos or a short video, comment, react. Every channel is
> moderated, and every post and comment can be reported in two taps.
>
> **Events.** The calendar of what's coming up. When an event finishes, everyone
> who was there can see everyone else who was there — for 48 hours, and then the
> list is gone. Add the people you actually met; the rest disappears. It is the
> only way to find someone in the app, and that is on purpose.
>
> **Private chat, genuinely private.** Messages are end-to-end encrypted on your
> device before they leave it. We store them, and we cannot read them. Not for
> advertising, not for analytics, not on request — the keys never leave your
> devices. You can verify a conversation's safety number, see every device that
> can read your messages, and revoke any of them.
>
> **Safety.** Block anyone, from anywhere you can see them. Report a post, a
> comment, an announcement, a member or a message — and because we cannot read
> private conversations, a chat report attaches the messages *you* choose,
> decrypted by your own device, so a moderator has something real to act on.
> Reports are triaged within 24 hours.
>
> You must be 18 or over. Your age band is confirmed through Apple's Declared Age
> Range, which tells us whether you are an adult and nothing else — we never ask
> for or store your date of birth.
>
> Delete your account at any time, from inside the app, in Settings.

*(Word it down if it runs long; the 4,000-character limit is not close.)*

## 3. Promotional text (170 max)

> Announcements, member forums, events, and private chat we genuinely cannot read.
> Invitation-only, 18+.

## 4. Keywords (100 characters, comma-separated, no spaces)

```
social club,members,community,forum,events,rsvp,private,group chat,encrypted,friends,invite only
```

96 characters. Notes: the app name's own words are not repeated (Apple indexes the
name separately), no competitor names, nothing suggestive, and no "dating" or
"hookup" terms — those would contradict the age-rating answers in §5 and invite a
2.3 metadata review.

---

## 5. Age rating questionnaire — **18+**

Commissioner decision (2026-08-10): no explicit content, **18+**. The rating is
driven by the private, adults-only membership and the unfiltered-by-design private
messaging, not by any content the app itself publishes.

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Realistic Violence | None |
| Sexual Content or Nudity | **None** |
| Profanity or Crude Humor | Infrequent/Mild |
| Alcohol, Tobacco, or Drug Use or References | Infrequent/Mild *(events are social and may be licensed premises)* |
| Mature/Suggestive Themes | Infrequent/Mild |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None |
| Gambling | No |
| Contests | No |
| **Unrestricted Web Access** | **No** — the app opens only its own hosted legal pages, in Safari |
| **Does your app contain user-generated content?** | **Yes** |
| — Does it include moderation? | **Yes** — see §7 |
| **Is the app a dating app / does it facilitate meeting new people romantically or sexually?** | **No.** It is a social club's members' app. Discovery is limited to people who attended the same event, in a 48-hour window, and there is no member search, no browsing, no profiles to swipe, no matching, no location, and no romantic or sexual intent expressed anywhere in the product. |
| Age assurance | **Apple Declared Age Range API**, gated at 18. A declared minor is refused. |

**On the name.** "fwb" is the club's own initialism and the app is named after the
club. Nothing in the name, subtitle, description, keywords, screenshots or in-app
content is sexual or suggestive, and the 18+ rating is set deliberately rather than
minimised. If App Review reads the name as a claim about the app's purpose, the
answer is the one above: no dating or hookup functionality exists in the product,
and §7's review notes point at the code paths that show it.

**Age assurance implementation.** `AgeGateService` asks Apple for three thresholds
(13, 16, 18) so the answer maps onto the server's bands exactly, and stores only the
band — `under_13` / `13_to_15` / `16_to_17` / `18_or_over` / `unknown`. No birthdate
is requested, transmitted or stored. Entitlement:
`com.apple.developer.declared-age-range`.

---

## 6. App Privacy — nutrition labels

**No third-party SDKs are linked.** The app has zero package dependencies
(`project.yml`); there is no analytics, advertising, attribution or crash-reporting
framework in the binary. Nothing is collected for tracking, and **App Tracking
Transparency does not apply** because no data is shared with data brokers or used
to track across apps or websites.

Answer **"Yes, we collect data from this app."** Then:

### Contact Info → Email Address
- **Used for:** App Functionality
- **Linked to the user:** Yes · **Used for tracking:** No
- Sign-in identity. Also matched against event check-ins to grant access (see the
  third-party note below). A Sign in with Apple private relay address is fully
  supported and is never resolved.

### Contact Info → Name
- **Used for:** App Functionality
- **Linked to the user:** Yes · **Used for tracking:** No
- The display name other members see.

### User Content → Photos or Videos
- **Used for:** App Functionality
- **Linked to the user:** Yes · **Used for tracking:** No
- Avatars, and photos/video attached to forum posts. **Photos sent in private chat
  are encrypted on the device before upload and are not readable by us.**

### User Content → Other User Content
- **Used for:** App Functionality
- **Linked to the user:** Yes · **Used for tracking:** No
- Forum posts, comments, reactions. **Private messages are end-to-end encrypted; we
  store ciphertext we cannot read.** The single exception is evidence a member
  chooses to attach to an abuse report, which their own device decrypts before
  sending — see §7.

### Identifiers → User ID
- **Used for:** App Functionality
- **Linked to the user:** Yes · **Used for tracking:** No

### Identifiers → Device ID
- **Used for:** App Functionality
- **Linked to the user:** Yes · **Used for tracking:** No
- The APNs push token, and the per-device encryption-key identity that makes E2EE
  and device revocation work.

### Not collected — answer "No" to all of these
Health & Fitness · Financial Info · **Precise or Coarse Location** · Physical
Address · Phone Number · Other Contact Info · Contacts · Browsing History · Search
History · **Usage Data** · **Diagnostics** · Purchases · Sensitive Info · Audio
Data · Gameplay Content · Customer Support · Other Data.

> **Location is genuinely not collected.** Event attendance comes from the
> organiser's Luma check-in records, never from the device — there is no location
> entitlement and no location API call in the app.

### Things the labels have no field for, which the **privacy policy must state**
1. **Luma is a third-party source.** Event and attendance data is pulled from the
   club's Luma calendar and matched to members by email address. Per Guideline
   5.1.2 and Luma's terms, those emails are used for matching only.
2. **What E2EE does and does not mean here** (PLAN.md §6.2). We cannot read message
   *content*. We do hold message *metadata* — sender, conversation, timestamp,
   device, size, type, read state, group membership, registered devices — and that
   metadata is producible. Do not describe this as "we know nothing."
3. **Losing every device loses history**, and a new phone does not inherit past
   messages. This is a property of the design, not a fault.
4. **There is no proactive scanning of private messages, ever.**
5. **Retention:** messages default to 365 days; moderation logs, resolved reports
   and reporter-submitted chat evidence are kept for 1 year (commissioner decision
   13). Attendance and friendship history are kept indefinitely (decision 14).
6. **Deletion:** deleting an account revokes the Apple grant, scrambles the
   identity and revokes every chat device. Forum authorship is tombstoned to
   "Deleted member" and posts are retained unless reported. Messages already
   delivered to other members' devices are unreachable by us and stay with them.

---

## 7. App Review notes

Paste into **App Review Information → Notes**.

> **What this app is.** fwb social is the private members' app for a social club.
> It is not a dating or hookup app: there is no member search, no browsing of
> members, no profile discovery, no matching, no swiping and no location. The only
> way to find another member is (a) a 48-hour attendee list after an event you both
> checked into, or (b) tapping the byline of a post they wrote in a forum. Both are
> demonstrable in the build. The app is rated 18+ and the age gate uses Apple's
> Declared Age Range API at 18; a declared minor is refused entry.
>
> **Signed-out access.** You do not need an account to see the app is real — the
> Home tab renders published announcements while signed out.
>
> ---
>
> **Private chat is end-to-end encrypted, and this changes what "moderation" can
> mean.** Messages are encrypted on the sending device (X-Wing: ML-KEM-768 +
> X25519, AES-GCM) and the server stores only ciphertext plus per-device wrapped
> keys. We cannot read private conversations and cannot produce their content.
> There is no proactive scanning of private messages, and there could not be.
>
> Guideline 1.2 is satisfied by mechanisms, and all of them are present:
>
> - **Filtering** — a blocked-terms filter flags forum posts, comments and
>   announcements for review. These are the server-readable surfaces and they are
>   held to the full standard.
> - **Report** — every post, comment, announcement, member and private message has
>   a report affordance. For a private message the reporter's own device decrypts
>   the messages they select and submits them as an evidence bundle, so a moderator
>   is not triaging blind. That evidence is stored encrypted at rest, is visible
>   only to moderators handling that report, and is retained for one year.
> - **Block** — from any surface a member appears on. Blocking filters feeds and
>   comments, and gates conversation creation and group invites in both directions.
>   Settings → Safety → Blocked members lists and reverses them.
> - **Ban** — moderators can ban an account, and choose per ban whether to delete
>   or tombstone everything that account wrote.
> - **24-hour SLA** — the first report on an item pushes the on-call moderator
>   immediately; the queue is ordered oldest-first because the SLA is about the
>   oldest.
>
> We also hold and can produce message *metadata* — who messaged whom, when, from
> which device, and group membership — which is what makes blocking, inbox privacy
> and abuse investigation work.
>
> ---
>
> **Demo account**
>
> Email: `<REVIEW_EMAIL>`
> Password: `<REVIEW_PASSWORD>`
>
> The account is already vetted, has accepted the terms, and is a member of a
> post-enabled channel and a comment-only channel, both with real content. It has
> one friend, an open post-event friending window with attendees, and one 1:1 and
> one group conversation.
>
> **Please read this before opening the Chat tab — it will look broken otherwise.**
>
> Signing in on your device registers that device's own encryption key, and by
> design a newly registered device can read messages sent **after** it registers,
> never messages sent before. This is the property that makes the encryption
> meaningful: a stolen password does not retroactively unlock a conversation. So
> **the seeded chat history is invisible to you, and that is correct behaviour, not
> a failure.**
>
> To see chat working end to end:
>
> 1. Sign in and open the **Chat** tab. Wait a few seconds for the banner to show
>    the device has finished setting up its keys.
> 2. Open either conversation. It will be empty or nearly so — expected, per above.
> 3. The partner account posts a fresh message into both threads **every 10
>    minutes**, so within ten minutes of your first sign-in you will see live
>    messages arrive and decrypt on your device.
> 4. Send a message yourself; the partner account replies automatically.
>
> Report and block are on the long-press menu of any message, and on the "…" menu
> of any post or comment.
>
> **Moderator tools.** The demo account is a moderator, so Settings → Moderation →
> Report queue is populated with example reports (including one chat report with a
> reporter-submitted evidence bundle), showing exactly what a moderator can and
> cannot see.
>
> **Account deletion** is in Settings → Account → Delete account, per 5.1.1(v).
>
> Anything else you need, we will turn it around same-day: `hello@fwb.events`.

### What must be true on production before that note is honest

- [ ] Reviewer account exists, is **vetted**, has **accepted the current terms**,
      and has a recorded age band of `18_or_over` — otherwise the reviewer hits the
      onboarding gate or a 403 wall.
- [ ] Reviewer account is a **moderator**, so the report queue is reachable.
- [ ] Channel membership: one post-enabled, one comment-only, both with posts,
      comments and reactions.
- [ ] An **open friending window** with attendees. A reviewer cannot manufacture a
      Luma check-in, so this must be seeded.
- [ ] A 1:1 and a group conversation exist with the partner account.
- [ ] **A scheduled job posts into both threads on a fixed short interval.** This is
      the load-bearing one. Without live traffic the reviewer sees empty threads and
      reasonably concludes chat is broken — PLAN.md §6.1 flags this as a real trap.
      Set the interval to match whatever the note above claims.
- [ ] Example reports in the queue, including one chat report with evidence.
- [ ] `legal.fwb.events` serving `/terms`, `/privacy`, `/guidelines`, `/support`.

---

## 8. Screenshots

**Required:** 6.9" iPhone (1320 × 2868). Apple scales that set down to the other
iPhone sizes, so no second set is needed for iPhone. Add a 13" iPad set only if the
app is submitted for iPad — `TARGETED_DEVICE_FAMILY` is `1,2`, so **either supply
iPad screenshots or drop the iPad family before submitting.**

Set, in order:

1. **Welcome** — the wordmark and the sign-in choices, establishing 18+ up front.
2. **Home / announcements** — the club's feed, populated.
3. **Channels** — a forum thread with attached media.
4. **Chat thread** — showing the encryption banner, so the headline claim is visible.
5. **Events** — an open friending window with its attendee roster and countdown.
6. **Profile** — membership status, friend code, and the route to account deletion.

Every shot must be free of anything suggestive and free of real members' data.

---

## 9. Build

| Field | Value |
|---|---|
| `MARKETING_VERSION` | `1.0` |
| `CURRENT_PROJECT_VERSION` | `1` |
| Minimum iOS | 26.0 |
| Device family | iPhone + iPad (`1,2`) — see §8 |
| Orientation | Portrait only on iPhone; all four on iPad |
| Capabilities required on App ID `events.fwb.social` | Sign in with Apple · Declared Age Range · Push Notifications · App Groups (`group.events.fwb.social`) · Keychain Sharing |
| Content rights | Contains third-party content: **No** |
| Advertising identifier (IDFA) | **No** |
