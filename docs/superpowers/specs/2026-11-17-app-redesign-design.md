# The app redesigned: Apple premium, three places

## Intent

Echo's Flutter app should look and feel like a premium Apple app, matching the pendant's
planned design (anodized black, silver and deep blue aluminium, a hidden azure light: see
`docs/hardware-design-fisico.md`). Today it reads as "Android dressed as an iPhone": Material
components, the Archivo font, an orange accent, and things scattered between a long Today page
and a Profile list that mixes settings with content.

Why now: the hardware is being redesigned premium; the app is what the user sees every day. The
user also wants the app's things easy to find, grouped by what they are.

Mockups the user approved:
- Style, Today in three directions: https://claude.ai/artifact/Rq2qLU2dMY2iwpactx3c3e
- Structure options: https://claude.ai/artifact/4XQbHXWKWhuVgKfQbdGZGv
- The chosen layout (Today, Library, account sheet): https://claude.ai/artifact/NfNCNv3Smj2NjqXhFT5pRQ

## Goals

- Two themes the user chooses between (System, Light, Dark; default System), designed as one
  system: **Midnight** (dark) and **Graphite** (light).
- One accent only, the pendant's azure, for "Echo is listening", the primary action and what is
  live. No orange.
- Three places: **Today** (the day at a glance), **Ask** (talk to Echo), **Library** (everything
  Echo keeps). The pendant and the settings live behind the user's circle, top right.
- iOS idioms where they show: tab bar, large titles that collapse on scroll, inset grouped
  lists, switches, bottom sheets, swipe back, haptics.
- Every feature the app has today keeps a home (mapping below).

## Non-goals

- New features. This is the same app, reorganised and restyled.
- A full rewrite in Cupertino or in Swift (approach 2; possibly later, see Approaches).
- A separate Android look. The app is iOS-first; Android gets the same design.
- Onboarding flow changes: it only takes the new theme.

## Anti-goals

- The generic "AI app" look: purple and cyan gradients, glowing everything, emoji as icons.
- Colour as decoration. The accent marks state and action, nothing else.
- Text below WCAG AA contrast in either theme.
- A redesign that leaves the app half old, half new for long: each phase ships whole.

## Constraints

- Flutter app in `mobile/` (Material 3 today, `EchoPalette` theme extension in
  `lib/theme/app_theme.dart`, theme choice already in `AppController.themeMode` with
  `ThemePreference.system|light|dark`).
- About 1,000 widget and unit tests run with `flutter test` in Docker; they must pass after each
  phase (tests that assert old labels or layout are updated, not deleted).
- `flutter analyze` keeps its 2 existing infos and adds none.
- iOS builds are started by the user only; never trigger `ios-unsigned.yml`.
- No new dependency for something Flutter's `cupertino` library already provides.
- Accessibility: Dynamic Type (text scales without clipping), VoiceOver labels on every control,
  44×44 pt touch targets, reduced motion respected.
- Every way into the app keeps landing where it should: notifications, the voice-answer nudge,
  shared items and any deep link open the same content as today, now inside its new home (a
  conversation opens in Library's stack, an answer in Ask).
- The same app is built for the web at `/app` (`mobile/web`, served from `site/app`); it must
  keep working there. Blur may fall back to an opaque bar where the browser lacks it.

## Approaches

1. **Restyle the theme only.** New colours and font in the current theme, a new tab bar, a new
   Library; Material components stay. Fastest, almost every test survives, but no collapsing
   large titles or real inset grouped lists: the premium look stays half done.
2. **Cupertino throughout.** Every screen rebuilt with Flutter's iOS components. The most
   faithful iOS look and behaviour, but close to a rewrite of the screens and most tests, and
   Android also looks like an iPhone.
3. **Hybrid (chosen).** The app stays a `MaterialApp` inside, and uses the iOS pieces where they
   show: `CupertinoSliverNavigationBar` large titles, `CupertinoListSection.insetGrouped` lists,
   `CupertinoSwitch`, Cupertino bottom sheets, iOS page transitions; everything else takes
   colours and type from the new theme. Premium where it counts, built one screen at a time,
   logic and most tests kept. Cost: two component families to keep consistent.

The user chose 3, noting the app may be rewritten completely later (approach 2 or native).

## Style

### Colour tokens

`EchoPalette` keeps its role-based design; its values change. New or renamed roles are the
builder's call as long as every colour comes from a token and both themes define all of them.

| Role | Midnight (dark) | Graphite (light) |
|---|---|---|
| Ground (`background`) | `#000000` | `#F5F5F2` |
| Panel (`surface`) | `#1C1C1E` | `#FFFFFF` |
| Tile, field (`surface2`) | `#2C2C2E` | `#F0F0ED` |
| Text (`text`) | `#E8E8ED` | `#1D1D1F` |
| Secondary text (`text2`) | `#8E8E93` | `#6E6E73` |
| Separator (`border`) | `#38383A` | `#E3E3E0` |
| Accent (`accent`): listening, primary action, live | `#64D2FF` | `#0A6FD6` |
| On accent | `#00141C` | `#FFFFFF` |
| Accent soft (selected rows, chips) | `#0B2A36` | `#E3EEF9` |
| Success (`green`) | `#30D158` | `#1E7A4D` |
| Warning (`amber`) | `#FFD60A` | `#8A5A00` |
| Error (`red`) | `#FF453A` | `#D70015` |
| Bars (tab bar, nav bar), translucent | `rgba(18,18,20,.92)` + blur | `rgba(245,245,242,.92)` + blur |

Measured contrast (WCAG): accent text `#64D2FF` on `#1C1C1E` 9.9:1, `#0A6FD6` on white 4.9:1
and on the ground 4.5:1; secondary text 5.2:1 (dark panel) and 4.6:1 (light ground). Apple's
`#0A84FF` was rejected for light text: 3.65:1 on white.

Roles that go away: `live`, `liveText`, `liveGlow` (orange) become the accent;
`attention`/`onAttention*` ("Needs you" in amber) become a normal panel whose action chip uses
the accent; `chrome*` (graphite bars) become the translucent bar tokens.

### Type

- The system font: San Francisco on iOS (Flutter's default typography on iOS when no
  `fontFamily` is set). Archivo is removed from the UI; it may stay only for the "Echo"
  wordmark.
- iOS text styles: Large Title 34, Title 1 28, Title 2 22, Headline 17 semibold, Body 17,
  Callout 16, Subheadline 15, Footnote 13, Caption 12; all scale with Dynamic Type.
- `tabular-nums` (`FontFeature.tabularFigures`) for times, percentages and counts.

### Components and motion

- Icons in the SF Symbols style: `CupertinoIcons`, one weight per level; no emoji.
- Large titles that collapse on scroll on the three main places and on Library pages.
- Inset grouped lists for every list of rows and every settings page.
- Bottom sheets (with grabber) for the account sheet and for the pendant's sheet.
- iOS page transitions with swipe back (`CupertinoPageTransitionsBuilder` for every platform).
- Spring curves for state changes; light haptics on confirmations (Done, Save, Mute); no
  animation when the system asks for reduced motion.
- Cards only where they set something apart (the Needs you item, Library tiles); no shadow in
  Midnight, a 1 px hairline at most in Graphite.

## Structure

### Tab bar

Three items: **Today**, **Ask** (centre, raised, accent fill: tap opens Ask, hold dictates as
today), **Library**. The user's circle (initial or photo) sits at the right of every large title
and opens the account sheet. Each tab keeps its own navigation stack and scroll position, as on
iOS: leaving Library on a person's page and coming back finds that page; tapping the active tab
again returns to its top.

### Today

Top: the pendant's status pill ("Echo is listening · 82%", or Muted, Off, Not connected, in the
state's words); a tap opens the pendant sheet. Then, in this order, each only when it has
something: **Needs you**, **Coming up**, **Now** (the live transcript, last lines with
speakers), **To do** (today's), **From your routines**, **Your day**. Edit Today stays, for
these sections only.

### Library

Top: search ("Search what you heard"; today's memory search). Then **This week**: one row per
day (date tile, number of conversations, the people), opening the day screen; "Earlier"
opens older days. Then a grid of tiles, two per row, each with a live count:
**People** (with faces), **Saved**, **To do** (all open), **Places**, **Map** (the memory graph),
**Documents**. Each tile opens today's screen for it, restyled.

### Ask

Unchanged in function: the thread with Echo, typed or spoken, photos, assistants switcher in the
header, history. Restyled: bubbles on panel colour, the input bar fixed at the bottom with the
microphone in the accent.

### The account sheet (the user's circle)

1. **The pendant** at the top: connection and listening state, battery, segments waiting,
   firmware version, Mute; a tap on it opens the full pendant screen (mic gain, updates, power).
2. **Echo does**: Routines, Apps (with WhatsApp), Notifications, Spoken answers, Activity.
3. **You**: About you (facts, instructions), Voices, Assistants, Language.
4. **Settings**: Appearance, Privacy, Places visited, Health, Plan, Devices, Server connection,
   Diagnostics, What Echo can do, Example data, About (with Log out and Delete account).

### Where today's things go

| Today | New home |
|---|---|
| Today: Needs you, Coming up, To do, From your routines, Your day | Today |
| Today: People, Saved, Where you've been, Earlier days | Library (tiles; Earlier days under This week) |
| Today: device warnings | Today, under the pendant pill |
| Ask (centre button, chat, history, assistants) | Ask |
| Memory search, memory graph, topic conversations, day and conversation screens | Library |
| Tasks screen | Library → To do (today's also on Today) |
| Profile: Plan, WhatsApp, Apps, Routines, Notifications, Activity | Account sheet → Echo does / Settings |
| Profile: Instructions, Memory (about you, documents) | Account sheet → You → About you; Documents also a Library tile |
| Profile: Assistants, Voices, Language | Account sheet → You |
| Profile: Privacy, Places visited, Health, Spoken answers, Appearance | Account sheet → Settings (Spoken answers under Echo does) |
| Profile: What Echo can do, Example data | Account sheet → Settings |
| More: Devices, Server connection, Diagnostics, About | Account sheet → Settings |
| Echo device screen | The pendant sheet (from Today's pill and the account sheet) |
| People screen, person page | Library → People |

## Phases

Each phase ships on its own, with `flutter analyze` and `flutter test` green, and can go on the
phone.

1. **Theme**: Midnight and Graphite tokens, system font, iOS page transitions, Cupertino icons
   where icons are swapped. Every screen takes the new colours; nothing moves.
2. **Navigation**: the three-item tab bar, the account sheet and the pendant sheet, the Profile
   entries moved into them. Today loses the sections that move to Library.
3. **Library**: search, This week, the tiles with counts, wired to today's screens.
4. **Screens, one at a time**: large titles and inset grouped lists on each screen (Today, Ask,
   day and conversation screens, People, person page, Saved, To do, Places, Map, settings
   pages), in an order the plan sets.

## Left to the builder

- Exact radii, spacing scale (on a 4 pt grid) and translucency values.
- How tile counts are fetched (existing endpoints; no new API unless one is missing).
- Which existing widgets are restyled and which are replaced by Cupertino ones, within the
  approach above.
- The order of screens in phase 4.

## Calls I made (to check)

- **To do appears twice**: today's items on Today, all open items as a Library tile.
- **The pendant's status** lives on Today as a pill, and in full at the top of the account sheet.
- **Spoken answers** goes under "Echo does" (it is something Echo does), not Settings.
- **Documents** is both a Library tile and part of About you, where it is today.
- **Edit Today** stays, for the sections Today keeps.
- **Android** gets the same design as iOS.
- **Light accent** is `#0A6FD6`, not Apple's `#0A84FF`, for contrast.
- **Each tab keeps its own stack**, and tapping the active tab returns to its top.
