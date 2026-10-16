# First run and sign-in — Design

Date: 2026-10-16. Status: discussed with the user; mockups approved on the design canvas
(https://claude.ai/artifact/6KQPTgMnHd1iFfYpqb2QZz, rows "First run" and "Welcome with sign-in").

## Intent

Today Echo opens straight on Today, after a white Flutter launch screen (a white flash in dark
mode). The first run starts with "Connect your backend" (server URL and API key), the most technical
step first, and ends with no proof that anything works. One shared API key (`my-secret-key` in the
README, rotation pending) is pasted into the app.

Echo will be sold one day as a **hosted service run by the user** (one server for all customers, like
Omi, Bee and Plaud), and the app must work on **Android as well as iOS**. Customers never see a
server address or a key: they sign in. This design gives Echo the first impression of a product and
the sign-in that the product needs, while today only the owner can get in.

## Goals

1. A launch screen in Echo's colours on every start, light and dark, iOS and Android: no white flash.
2. A welcome screen, first run only, that shows what Echo is and holds the sign-in buttons.
3. Sign-in with email and password that gives **each phone its own key**; no server URL or API key
   ever asked of the user.
4. The first run ends with a first result: the user says something and sees Echo understand it.
5. Settings can show this phone and the others signed in, sign this phone out, and revoke another.

## Non-goals (for now)

- Sign in with Apple and Google: drawn on the welcome screen, **not built**. Apple needs the paid Apple
  developer account, which the user does not have yet; App Store rules then require Apple whenever
  Google is offered, so both come together, later.
- Registration from the app, email verification, password reset by email (needs an email service):
  they come with the sale. Registration is **closed**: accounts are created on the server.
- Full multi-user hardening (every worker, integration and quota per user): a separate project before
  selling. This design only must not make it harder.
- Two-step verification.
- Android equivalents of the iOS-only features (Reminders, Calendar via EventKit, Live Activity).

## Anti-goals

- An API key, a password or any secret compiled into the app or committed to git.
- An open sign-up endpoint on a server reachable from the internet.
- A long carousel of intro slides.
- Breaking the owner's existing install: the app on the user's phone must keep working across the
  update (see Migration).

## What the user decided

- **Accounts:** email + password now; Apple and Google later, together.
- **Server address:** fixed in the app (`BuildDefaults.serverUrl`), never shown in the first run.
  Changing it stays possible in Settings → Server connection (for development).
- **Registration closed:** the owner's account is created on the server with a command.
- **Welcome screen:** the mixed version ("Welcome A + B: the device catches your words"):
  - graphite ground and the device large, with its LED breathing;
  - orange rings widening like sound;
  - three short spoken phrases appear around the device, fly into it, and two memories appear below
    it (a promise and a calendar event) in the dark palette;
  - the title "Your day, remembered.", and one line, "Say it once. Echo keeps it, and what you
    promised.";
  - the buttons "Continue with Apple", "Continue with Google" and "Continue with email";
  - with reduced motion, nothing moves and the two memories show still.
- **First-run order:** launch → welcome (with sign-in) → email sign-in → permissions → pair your Echo
  → you control listening → first result → Today.
- Everything works the same on Android.

## The screens (mockups on the canvas)

| # | Screen | Notes |
|---|---|---|
| 1 | Launch | The device mark with its LED and "Echo", on the app background (light `#E9EAE7`, dark `#1C1E20`). Native splash on both platforms; follows light/dark. Nothing to tap. |
| 2 | Welcome | As decided above. Apple and Google are shown; a tap says they are coming soon. |
| 3 | Continue with email | Back, title, email, password, "Forgot your password?", a note that this phone gets its own key that can be signed out from Settings, "Sign in". Errors inline: wrong email or password (one message for both), too many attempts (with the wait), no connection. "Forgot your password?" opens a short sheet: for now a password is reset by whoever runs the Echo server. |
| 4 | Permissions | Bluetooth (required), Notifications and Microphone (optional), each with "Allow"; wording works on Android too. Exists today: restyle to the mockup. |
| 5 | Pair your Echo | The device blinking, "Echo found, battery 82%", Pair; "I don't have it with me" skips. Exists today: restyle. |
| 6 | You control listening | The orange pill, the muted pill, the button on the device; a line on where data stays; "Start listening". Exists today: restyle. |
| 7 | First result | "Try it now. Say: Echo, remind me to call Giulia on Friday at six." What Echo heard, then what it understood (the task with its time), "Go to Today", "Skip". |

A progress bar of four parts runs over screens 3–6 (sign-in, permissions, pairing, privacy), with a
back button. The old "Connect your backend" step goes away from the first run.

## Server: accounts and per-device keys

What exists: `api_keys` (user_id, SHA-256 `key_hash`, name, last_used_at); every request resolves its
user from `X-API-Key`; failed keys are rate-limited per client (10 per 15 minutes, `core/auth.py`).
Data is already scoped by `user_id` in the routers. Keys are created with `make create-key` for the
fixed user `a0000000-0000-0000-0000-000000000001`.

Add:

- **`users`** table: id (UUID), email (unique, stored lower-cased), password hash (**Argon2id**), created_at.
- **`api_keys`** gains what a phone needs:
  - a device name ("Erik's iPhone", sent by the app);
  - the platform (ios/android);
  - created_at (exists through the mixin) and last_used_at (exists).
  Keys issued at sign-in are random (32 bytes, URL-safe) and stored only as their hash, like today.
- **`POST /api/auth/login`** {email, password, device_name, platform} → {api_key, user} once.
  - A wrong email and a wrong password give the same 401.
  - The existing failure limiter applies, per client and also per email.
  - A password check runs even for unknown emails, so timing doesn't reveal accounts.
- **`POST /api/auth/logout`** (authenticated): deletes the calling key.
- **`GET /api/auth/devices`**: the user's keys, without hashes, with name, platform, created and last
  used, and which one is this phone.
- **`DELETE /api/auth/devices/{id}`**: revokes one of the user's own keys.
- **No sign-up endpoint.** `make create-user EMAIL=…` asks for the password twice and creates the user.
  `make set-password EMAIL=…` resets it.
- When Apple/Google arrive, they become other ways into the same "issue a key for this phone" step.

## App

- Launch screen: native splash on iOS (LaunchScreen.storyboard with light/dark assets) and Android
  (Android 12 splash API, plus the pre-12 fallback). Same mark on both.
- Welcome: a Flutter animation, with no video or Lottie dependency unless the builder finds one
  necessary; respects reduced motion (`MediaQuery.disableAnimations`).
- Credentials: the key keeps going to the Keychain / Android Keystore (`flutter_secure_storage`,
  already in use); the server URL comes from `BuildDefaults`.
- Onboarding: steps become welcome, email sign-in, permissions, pairing, privacy, first result. The
  backend step leaves the first run.
- Settings:
  - "Devices" lists the signed-in phones, with "Sign out" for this one and "Revoke" for others.
  - Log out (About) calls `/api/auth/logout` before clearing local data.
- A 401 on any request (key revoked elsewhere) signs the phone out and returns to the welcome screen
  with a short message.

## First result

The user says "Echo, …" wearing the device; the app shows what was heard, then what Echo did.

- Voice requests ("Echo, …") are answered faster than ordinary conversations, which take minutes to be
  analysed.
- If the result has not come within about 30 seconds, the screen says Echo is still working and the
  result will be on Today, and lets the user go on.
- Without a paired Echo (pairing skipped), the screen is skipped.

## Migration (the owner's phone)

The existing install has a pasted API key for the fixed user and no account.

- `make create-user` for the owner must attach to the **existing** user id, so all current data stays
  theirs.
- Old keys keep working after the update, so the phone is not signed out.
- The README example key is revoked as already planned (`make revoke-example-key`).
- Afterwards the owner can sign in again to get a per-device key and revoke the old pasted one.

## Constraints

- App UI copy in English; the AI stays multilingual.
- iOS and Android behave the same for everything in this design.
- No secret in the app or in git; `dart_defines.json` keeps only the server URL.
- Existing tests keep passing; new endpoints and screens get tests.
- The Flutter project already has an `android/` folder; it is checked with an Android debug build
  (`flutter build apk --debug`) as well as the iOS one.

## Calls made by Claude (check these)

- Settings → Server connection stays, for development; it is never part of the first run.
- "Forgot your password?" shows a sheet for now instead of an email flow.
- A revoked key (401 anywhere) signs the phone out to the welcome screen.
- Log out keeps doing what it does today (stops Bluetooth, clears the key, the paired wearable and the
  cache) and also deletes its key on the server.
- The first result waits about 30 seconds before falling back to "you'll find it on Today", and is
  skipped when pairing was skipped.

## Apple and Google before they work

Decided by the user: the buttons are **shown**; a tap says they are coming soon and points to "Continue
with email".

## Left to the builder

- The exact animation timing and the Flutter technique for the welcome.
- How to generate the native splash (by hand or with a package such as `flutter_native_splash`).
- The Argon2 library on the server and its parameters (sensible OWASP defaults).
- How the app sends the device name (iOS/Android device model, or "iPhone"/"Android phone" plus the
  user's first name).
- The first-result plumbing, within the 30-second behaviour above.
