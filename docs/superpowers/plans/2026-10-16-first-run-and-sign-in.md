# First Run and Sign-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the server-and-key first run with a branded launch, a welcome that holds sign-in,
email + password sign-in that gives each phone its own key, and a first result; add a Devices page.

**Architecture:**
- **Server:**
  - A `users` table with Argon2id password hashes.
  - A login endpoint that issues a per-phone `api_keys` row; no sign-up endpoint.
  - Accounts are created by a CLI run through `make`.
- **App:**
  - `OnboardingStep.backend` becomes `signIn`, which shows the welcome and then the email form; a
    `firstResult` step is added at the end.
  - The API client reports 401s so the session can sign the phone out.
  - Native splash screens on iOS and Android.

**Tech Stack:**
- Server: FastAPI, SQLAlchemy async, Alembic, Postgres 16, Redis, `argon2-cffi`.
- App: Flutter, Dart; `flutter_secure_storage` (already in use); native splash files.

**Spec:** [docs/superpowers/specs/2026-10-16-first-run-and-sign-in-design.md](../specs/2026-10-16-first-run-and-sign-in-design.md)

## Global Constraints

- App UI copy in English only; the AI stays multilingual.
- iOS and Android behave the same; verify with `flutter build ios --debug --no-codesign` and
  `flutter build apk --debug`.
- No secret in the app or in git; `dart_defines.json` / `dart_defines.example.json` keep only
  `ECHO_SERVER_URL`.
- Registration closed: no sign-up endpoint; accounts only via `make create-user`.
- Wrong email and wrong password give the same 401 and the same message: "Wrong email or password."
- The owner's existing user id is `a0000000-0000-0000-0000-000000000001`; their data must stay theirs.
- Keys issued at sign-in are random (32 bytes, `secrets.token_urlsafe(32)`), stored only as SHA-256
  (`hash_api_key`), like today.
- Failed sign-ins use the existing limiter: `AUTH_FAILURE_LIMIT = 10`, `AUTH_FAILURE_WINDOW_SECONDS = 15 * 60`,
  per client address and also per email.
- Reduced motion (`MediaQuery.disableAnimationsOf`) stops every welcome animation; the two memories
  show still.
- Backend tests: `docker compose exec -T -e DATABASE_URL=postgresql+asyncpg://echo:echo@postgres:5432/echo_test -e REDIS_URL=redis://redis:6379/15 api python -m pytest tests/ -q -p no:cacheprovider`
  (never pass env through a shell variable in zsh). App: `flutter analyze` and `flutter test` in `mobile/`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never stage the
  user's `.gitignore` change.

## Review Focus

1. **Email typed with capitals or spaces** ("  Erik@Example.com ") signs in to the same account →
   Task 2 test `test_login_email_is_case_and_space_insensitive`.
2. **Server unreachable during sign-in** shows "No connection. Check your internet and try again.",
   never "Wrong email or password." → Task 4 test `signIn reports no connection, not wrong password`.
3. **Key revoked while the app runs** (many requests 401 at once, uploads in background) signs out
   exactly once and lands on the welcome with "This phone was signed out." → Task 3 test
   `many 401s sign out once`.
4. **Updating the owner's phone** (legacy pasted key, onboarding complete, highest step 3) opens
   straight on Today, not the welcome → Task 4 test `a completed legacy install skips sign-in`.
5. **Sign-in hammered with wrong passwords for one email from many addresses** is limited per email →
   Task 2 test `test_login_limited_per_email_across_clients`.

---

### Task 1: Users and password hashing on the server

**Files:**
- Create: `backend/app/models/user.py`, `backend/alembic/versions/015_users_and_device_keys.py`,
  `backend/app/services/passwords.py`, `backend/app/cli/__init__.py`, `backend/app/cli/users.py`
- Modify: `backend/app/models/__init__.py` (export `User`), `backend/app/models/api_key.py` (add
  `platform`), `backend/pyproject.toml` (add `"argon2-cffi==23.1.0"`), `backend/tests/conftest.py`
  (delete from `users` in teardown; delete keys other than the test key), `Makefile` (targets
  `create-user`, `set-password`)
- Test: `backend/tests/test_users.py`

**Interfaces:**
- Produces:
  - `User(id: UUID, email: str, password_hash: str, created_at)`, table `users`, unique `email`
    (stored `strip().lower()`).
  - `ApiKey.platform: str | None` (`String(20)`): "ios" or "android".
  - `hash_password(password: str) -> str` and `verify_password(password_hash: str, password: str) -> bool`
    in `app/services/passwords.py`; `verify_password` returns False on any mismatch or a malformed hash.
  - `DUMMY_PASSWORD_HASH: str`, a hash to verify against when the email is unknown.
  - `normalize_email(email: str) -> str`.
  - `async create_user(db, email: str, password: str, user_id: UUID | None = None) -> User`:
    `user_id` None makes a new uuid4; raises `ValueError("email already exists")` and
    `ValueError("password must be at least 10 characters")`.
  - `async set_password(db, email: str, password: str) -> None`: `ValueError("no such user")`.
  - CLI: `python -m app.cli.users create --email E [--user-id UUID]` and
    `python -m app.cli.users set-password --email E`; both ask the password twice with `getpass`.

- [ ] **Step 1: Write the failing tests** in `tests/test_users.py`:
  - `test_hash_and_verify`: `verify_password(hash_password("correct horse battery"), "correct horse battery") is True`,
    and the wrong password gives False.
  - `test_verify_rejects_malformed_hash`: `verify_password("not-a-hash", "x") is False`.
  - `test_create_user_attaches_to_existing_id`: `create_user(db, " Erik@Example.com ", "long enough pw", user_id=TEST_USER_ID)`,
    then `user.id == TEST_USER_ID` and `user.email == "erik@example.com"`.
  - `test_create_user_rejects_duplicate_and_short_password`: the same email again raises
    `ValueError("email already exists")`; `"short"` raises the length error.
  - `test_set_password_changes_hash`: the old password fails and the new one verifies.
- [ ] **Step 2: Run them** — `... python -m pytest tests/test_users.py -q`. Expected: FAIL (import errors).
- [ ] **Step 3: Implement**
  - The model, the migration and the services.
  - Migration 015, revises 014: create `users`; `add_column("api_keys", platform String(20) nullable)`.
    Guard with `sa_inspect` like 014.
  - Passwords: `argon2.PasswordHasher()` defaults; `verify_password` catches `argon2.exceptions.VerifyMismatchError`,
    `InvalidHashError` and `VerificationError`.
  - The CLI: `async_session` from `app.core.database`; prints "Created erik@example.com (a000…)" and never
    prints the password.
- [ ] **Step 4: Makefile**
  - `create-user`: `docker compose exec api python -m app.cli.users create --email $(EMAIL) --user-id $${USER_ID:-a0000000-0000-0000-0000-000000000001}`.
  - `set-password`: `docker compose exec api python -m app.cli.users set-password --email $(EMAIL)`.
  - Both with `##` help lines in the style of `create-key`.
- [ ] **Step 5: Run the tests again**, plus `tests/test_migrations.py`. Expected: PASS.
- [ ] **Step 6: Commit** — "feat(server): accounts with Argon2 passwords, created from the command line".

### Task 2: Sign-in, sign-out and devices endpoints

**Files:**
- Create: `backend/app/routers/auth.py`
- Modify: `backend/app/core/auth.py` (add `get_current_api_key`; `get_current_user_id` uses it;
  per-email failure key), `backend/app/main.py` (include the router)
- Test: `backend/tests/test_auth_login.py`

**Interfaces:**
- Consumes: Task 1's `User`, `verify_password`, `DUMMY_PASSWORD_HASH`, `normalize_email`, `ApiKey.platform`.
- Produces (prefix `/api`):
  - `POST /auth/login`:
    - request `{email, password, device_name (1–100 chars), platform ("ios"|"android")}`;
    - 200 `{"api_key": str, "device_id": str, "user": {"id": str, "email": str}}`;
    - 401 `{"detail": "Wrong email or password."}`;
    - 429 `{"detail": "Too many attempts. Try again in N minutes."}` with `Retry-After`.
  - `POST /auth/logout` (X-API-Key): 204; deletes the calling key.
  - `GET /auth/devices` (X-API-Key): 200, a list of
    `{"id","name","platform","created_at","last_used_at","current": bool}`, newest first, only the
    caller's user.
  - `DELETE /auth/devices/{id}`: 204; 404 when the id is not one of the caller's keys.
  - `get_current_api_key(request, api_key, db) -> ApiKey`, with the same limiter behaviour as today.

- [ ] **Step 1: Write the failing tests:**
  - `test_login_issues_a_key_that_works`: create a user with `TEST_USER_ID`; login → 200; the returned
    key opens `GET /api/conversations`; the `api_keys` row has `name == device_name` and
    `platform == "ios"`.
  - `test_login_wrong_password_and_unknown_email_look_the_same`: both 401 with the identical detail.
  - `test_login_email_is_case_and_space_insensitive` (Review Focus 1).
  - `test_login_limited_per_client`: 10 wrong attempts → the 11th is 429 even with the right password.
  - `test_login_limited_per_email_across_clients` (Review Focus 5): 10 wrong attempts with
    `CF-Connecting-IP` varying → 429 for that email from a new address; another email still gets 401
    and not 429.
  - `test_logout_deletes_only_the_calling_key`: two logins; logout with the first; the first gets 401
    and the second still works.
  - `test_devices_lists_own_keys_and_marks_current`: no hash in the payload; another user's keys are
    absent.
  - `test_revoke_other_device_and_404_for_foreign_id`.
- [ ] **Step 2: Run them.** Expected: FAIL (404s).
- [ ] **Step 3: Implement the router.**
  - On an unknown email, verify against `DUMMY_PASSWORD_HASH` before answering 401.
  - Record failures under both `auth_fail:<client>` and `auth_fail_email:<sha256(email)[:16]>` with
    the existing `_check_not_blocked` / `_record_failure`.
  - Clear neither key on success (the window expires on its own).
  - The 429 detail rounds the TTL up to whole minutes.
- [ ] **Step 4: Run the whole backend suite.** Expected: all pass (the existing 642 + new).
- [ ] **Step 5: Commit** — "feat(server): email sign-in that gives each phone its own key".

### Task 3: App API: sign in, sign out, devices, and 401s

**Files:**
- Create: `mobile/lib/services/api/auth_api.dart`, `mobile/lib/models/signed_in_device.dart`
- Modify: `mobile/lib/services/api/api_client.dart` (an `unauthorized` stream fed by every 401 from
  `send`), `mobile/lib/services/api/api_service.dart` (mix in `AuthEndpoints`, export),
  `mobile/lib/services/app/session_controller.dart` (sign out on 401, once; a `reason` in state),
  `mobile/lib/models/session_state.dart` (`SessionState.reason: String?`),
  `mobile/lib/services/app/app_lifecycle_coordinator.dart` (wire the stream)
- Test: `mobile/test/services/api/auth_api_test.dart`, `mobile/test/services/app/session_controller_test.dart`

**Interfaces:**
- Produces:
  - `mixin AuthEndpoints on ApiClient`:
    - `Future<void> signIn({required String email, required String password})`: posts to `/api/auth/login`
      with `device_name` = `Platform.isIOS ? 'iPhone' : 'Android phone'` and `platform` = `'ios'|'android'`,
      then `credentials.configure(BuildDefaults.serverUrl, apiKey)`;
    - `Future<void> signOutThisPhone()`: `POST /api/auth/logout`; a 401 also counts as done;
    - `Future<List<SignedInDevice>> listDevices()`;
    - `Future<void> revokeDevice(String id)`.
  - `SignInException implements Exception` with `SignInFailure reason`
    (`wrongCredentials`, `tooManyAttempts`, `noConnection`, `server`) and `String message`.
    The messages:
    - wrong credentials: "Wrong email or password.";
    - too many attempts: the server's detail;
    - no connection: "No connection. Check your internet and try again.";
    - server: "Echo could not sign you in. Try again.".
  - `SignedInDevice(id, name, platform, createdAt, lastUsedAt?, current)`.
  - `ApiClient.unauthorized: Stream<void>` (broadcast).
  - `SessionController.signOutRevoked()`: performs `logout()` with `reason: 'This phone was signed out.'`;
    ignored while already logging out or logged out.

- [ ] **Step 1: Write the failing tests** with a fake `http.Client`:
  - `signIn stores the issued key for the build server`.
  - `signIn maps 401, 429, socket errors and 500 to SignInFailure` (the exact messages above).
  - `listDevices parses the server list`.
  - `many 401s sign out once` (Review Focus 3): three 401s on the stream → one `logout`, and the state
    reason is "This phone was signed out.".
- [ ] **Step 2: Run** `flutter test test/services/api/auth_api_test.dart test/services/app/session_controller_test.dart`.
  Expected: FAIL.
- [ ] **Step 3: Implement.** The existing About → Log out calls `signOutThisPhone()` before clearing
  locally; failure to reach the server does not block a local logout.
- [ ] **Step 4: Run the full app suite** (`flutter analyze`, `flutter test`). Expected: pass.
- [ ] **Step 5: Commit** — "feat(mobile): sign in, sign out and the phone's own key".

### Task 4: Onboarding steps: sign-in instead of the server, first result at the end

**Files:**
- Modify: `mobile/lib/services/onboarding/onboarding_controller.dart`,
  `mobile/lib/services/onboarding/onboarding_adapters.dart`, `mobile/lib/main.dart`
  (`_createDefaultOnboardingController`)
- Test: `mobile/test/services/onboarding/onboarding_controller_test.dart` (create);
  `mobile/test/screens/onboarding_test.dart` and `mobile/test/widget_test.dart` (update)

**Interfaces:**
- Consumes: Task 3's `signIn`, `SignInException`.
- Produces:
  - `enum OnboardingStep { signIn, permissions, pairing, privacy, firstResult }`, with the same indexes as
    before for the first four, so the stored `highestStepKey` keeps its meaning.
  - `OnboardingApi { Future<bool> isConfigured(); Future<void> signIn(String email, String password); }`.
  - `OnboardingController.signIn(String email, String password)`:
    - empty fields → error "Enter your email and password.";
    - on `SignInException`, `error = e.message`;
    - on success, step becomes `permissions`.
  - `OnboardingController.finishPrivacy()`: privacy → `firstResult` when paired, else `complete()`.
  - `complete()` is called from `firstResult` (Go to Today or Skip).
  - `OnboardingState.showWelcome: bool`: true on `signIn` until `continueWithEmail()`;
    `backToWelcome()` sets it back.
  - `submitBackend` is removed.

- [ ] **Step 1: Write the failing tests:**
  - `a fresh install starts on the welcome`.
  - `signIn reports no connection, not wrong password` (Review Focus 2).
  - `a completed legacy install skips sign-in` (Review Focus 4): `isConfigured` true, highest 3,
    `completedKey` true → `completed == true`.
  - `privacy goes to first result only when paired`.
  - `goBack from permissions returns to the email form, not the welcome`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement**, keeping `_initialize`'s resume logic with `signIn` in place of `backend`.
- [ ] **Step 4: Run the full app suite.** Expected: pass after the widget tests are updated to the new steps.
- [ ] **Step 5: Commit** — "feat(mobile): first run starts with sign-in and ends with a first result".

### Task 5: Welcome, email sign-in and the restyled steps

**Files:**
- Create: `mobile/lib/screens/onboarding/welcome_step.dart` (the current privacy content moves to
  `privacy_step.dart`), `mobile/lib/screens/onboarding/email_sign_in_step.dart`,
  `mobile/lib/widgets/echo_device_mark.dart` (the device with its LED, sizes as parameters, used by
  the welcome, pairing and splash artwork), `mobile/lib/widgets/onboarding_progress.dart`
- Modify: `mobile/lib/screens/onboarding/onboarding_screen.dart`, `permissions_step.dart`,
  `pairing_step.dart`; delete `backend_step.dart`
- Test: `mobile/test/screens/onboarding_test.dart`

**Interfaces:**
- Consumes: Task 4's controller API.
- Produces:
  - `EchoDeviceMark({double size = 120, bool breathing = false})`.
  - `OnboardingProgress({required int step})` (1–4).
  - Keys:
    - `welcome-apple`, `welcome-google`, `welcome-email`;
    - `sign-in-email`, `sign-in-password`, `sign-in-submit`, `sign-in-forgot`;
    - `onboarding-progress`.

The look is the canvas boards "Welcome A + B: the device catches your words", "Continue with email",
"4. Permissions", "5. Pair your Echo", "6. You control listening"
(https://claude.ai/artifact/6KQPTgMnHd1iFfYpqb2QZz). The welcome's copy is fixed:
- title "Your day, remembered.";
- line "Say it once. Echo keeps it, and what you promised.";
- phrases "Both options by Friday?", "Thursday night, sure.", "Lunch Tuesday at one?";
- memories "Promise to Marco / Both options, Thu" and "Calendar / Lunch, Tue 13:00";
- buttons "Continue with Apple", "Continue with Google", "Continue with email".

The welcome is always on the graphite ground (`EchoPalette.dark`), whatever the theme.

- [ ] **Step 1: Write the failing widget tests:**
  - `Apple and Google say they are coming`: a tap shows a sheet with "Sign in with Apple is coming
    soon. For now, continue with email.", and the same text for Google.
  - `email form signs in and shows the server's message on failure`.
  - `forgot password explains the reset`: the sheet text is "For now, a password is reset by whoever
    runs your Echo server."
  - `reduced motion keeps the welcome still and shows both memories`: with `disableAnimations: true`,
    no `AnimationController` is ticking (`tester.binding.hasScheduledFrame` is false after a pump)
    and both memory texts are visible.
  - `the welcome fits 320x640 at 1.3 text scale, light and dark`.
  - `progress shows steps 1–4 on email, permissions, pairing and privacy`.
  - `a revoked phone sees why on the welcome`: with `SessionState.reason` "This phone was signed out.",
    the welcome shows that line above the buttons (passed to `OnboardingScreen` as
    `String? notice`).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** One `AnimationController` of 8 s, repeating, drives the rings, the LED,
  the phrases and the memories, following the canvas keyframes. Dispose it.
- [ ] **Step 4: Run** `flutter analyze` and `flutter test`. Expected: pass.
- [ ] **Step 5: Commit** — "feat(mobile): the welcome, email sign-in and the setup steps in the new look".

### Task 6: First result

**Files:**
- Create: `mobile/lib/screens/onboarding/first_result_step.dart`,
  `mobile/lib/services/onboarding/first_result_watcher.dart`
- Modify: `mobile/lib/screens/onboarding/onboarding_screen.dart`
- Test: `mobile/test/services/onboarding/first_result_watcher_test.dart`, `mobile/test/screens/onboarding_test.dart`

**Interfaces:**
- Consumes: `VoiceWorkingApi.getVoiceWorking()` and `VoiceUpdatesApi.getVoiceUpdates(DateTime? since)`
  (existing).
- Produces:
  - `FirstResultWatcher({required VoiceWorkingApi working, required VoiceUpdatesApi updates,
    Duration poll = const Duration(seconds: 2), Duration patience = const Duration(seconds: 30),
    DateTime Function() clock})`.
  - It extends `ValueNotifier<FirstResultState>`, where
    `FirstResultState(heard: String?, answer: String?, gaveUp: bool)`.
  - `start()` and `dispose()`.
  - `heard` comes from the first voice working item's text, or from the first user message after
    `start`; `answer` comes from the first assistant message after `start`.

- [ ] **Step 1: Write the failing tests** with fake APIs and `fake_async`:
  - `shows what was heard, then the answer`.
  - `gives up after 30 seconds without an answer`: `gaveUp` is true, and the screen says "Echo is still
    working on it. You'll find it on Today."
  - `ignores answers from before the screen opened`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the watcher and the screen. The screen follows the canvas board "7. First
  result", shows the answer text under "Echo understood", and has "Go to Today" and "Skip".
- [ ] **Step 4: Run the app suite.** Expected: pass.
- [ ] **Step 5: Commit** — "feat(mobile): the first run ends with something Echo understood".

### Task 7: Devices in Settings

**Files:**
- Create: `mobile/lib/screens/settings/devices_screen.dart`
- Modify: `mobile/lib/screens/settings_screen.dart` (a "Devices" row in the last group, before About,
  subtitle "Phones signed in to your account.")
- Test: `mobile/test/screens/devices_screen_test.dart`

**Interfaces:**
- Consumes: Task 3's `listDevices`, `revokeDevice`, `signOutThisPhone`, `SessionController.logout`.
- Produces:
  - `DevicesScreen({AuthEndpoints? api, SessionController? session})`.
  - The current phone row is marked "This phone" and offers "Sign out" (confirm dialog, then logout).
  - The other rows offer "Revoke" (confirm dialog "Revoke <name>? It will have to sign in again.").

- [ ] **Step 1: Write the failing tests:**
  - `lists phones with this one first`.
  - `revoke removes the row`.
  - `sign out of this phone logs out`.
  - `a failed load offers Retry`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** with `SettingsPageScaffold` and `SettingsRow`.
- [ ] **Step 4: Run the app suite.** Expected: pass.
- [ ] **Step 5: Commit** — "feat(mobile): see and revoke the phones signed in".

### Task 8: Launch screens, builds and docs

**Files:**
- Modify:
  - iOS: `mobile/ios/Runner/Base.lproj/LaunchScreen.storyboard`,
    `mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/*` (light and dark appearances).
  - Android: `mobile/android/app/src/main/res/drawable*/launch_background.xml`,
    `values*/styles.xml`; add `values-v31` and `values-night-v31` for the Android 12 splash.
  - `mobile/dart_defines.example.json`; `README.md` and `docs/DEVELOPMENT.md` (`make create-user` and
    `make set-password`, the first run, `make revoke-example-key`).
- Create: the splash artwork PNGs (the device mark on the background), generated once from
  `EchoDeviceMark`; or `flutter_native_splash` as a dev dependency, if its output matches.

Spec values:
- Background light `#E9EAE7`, dark `#1C1E20`.
- Mark: graphite `#2E3133` disc, ring `#464B4F`, LED `#E8590C`.
- No text other than "Echo".

- [ ] **Step 1: Make the splash files** (light and dark, iOS and Android).
- [ ] **Step 2: Build both platforms** — `flutter build ios --debug --no-codesign` and
  `flutter build apk --debug` in `mobile/`. Expected: "✓ Built" for both.
- [ ] **Step 3: Update the docs and `dart_defines.example.json`** (server URL only).
- [ ] **Step 4: Run** `flutter analyze` and `flutter test` one last time. Expected: pass.
- [ ] **Step 5: Commit** — "feat(mobile): Echo's launch screen on iOS and Android".
