# Places visited — Design

Date: 2026-10-24. Status: asked by the user on 23–24/10 ("se echo può registrare le visite sarebbe
comodo"); written up for approval.
It changes a decision of 16/10 ("no history of places visited"; also an anti-goal of
`2026-10-23-saved-design.md`) **for the users who turn it on**: off by default, it stays as decided for
everyone else.

## Intent

Echo knows what was said and with whom, not where. The user wants Echo to know where they were, so that
"dove siamo stati sabato?", "in che ristorante abbiamo cenato con Marco?", "quando sono stato dal
dentista?" are answered, and the day reads as places and conversations together ("Cena con Marco —
Trattoria da Mario").

Google Maps Timeline cannot be read (on the phone only since 2024–25, no API, no MCP): Echo records
the visits itself, with the phone's low-power visit detection.

## Goals

1. **An option in Profile → Places visited**, off by default. Turning it on explains what is kept and
   asks for the location permission "Always" (needed to notice visits with the phone in a pocket);
   turning it off stops recording at once and offers to delete what was kept.
2. **Visits, not tracks**: a visit is a stay (arrived, left, where, the address and, when the phone
   knows it, the place's name). No path between places, no continuous positions kept.
3. **Visits meet conversations**: a conversation during a visit shows the place (on its card, in Your
   day, in its page); answers can use it.
4. **Questions about places** ("dove siamo stati sabato?", "quando sono andato in palestra l'ultima
   volta?", "dove ho cenato con Marco?") answered from the visits and the conversations together, by
   chat and voice.
5. **The user's control**: the visits listed by day in Profile → Places visited (delete one, delete a
   day, delete all); kept 90 days, then deleted; never sent to outside assistants (MCP), like Saved's
   places.

## Non-goals (for now)

- Importing Google Maps Timeline files (a later option for those who have them).
- Paths, distances walked, transport mode, a map of the day.
- Place names from paid services (Google Places): the phone's own geocoder and, on iPhone, Apple's
  place names where available.
- Sharing visits with anyone; visits used for notifications ("you are near the shop on your list").

## Anti-goals

- Recording without the option on, or after it is turned off.
- A battery drain the user notices: only the operating system's low-power visit and significant-change
  services, no continuous GPS.
- Places shown to other people or assistants.
- Visits presented as certain when they are not: a short or vague stay is not a visit.

## Constraints

- iOS and Android; the app is kept alive by Bluetooth (iOS background mode) and on Android by the
  foreground service `EchoStatusService`. English UI copy; AI in the user's language.
- iOS: `CLLocationManager.startMonitoringVisits` (the system's visit detection, low power) needs
  "Always" authorization; Android has no visit API: the builder picks the low-power route (fused
  location at low power from the foreground service, stays worked out from the points).
- Backend: next migration after the ones on main at build time; tests one suite at a time; work lands
  on main, verified.

## What the user decided

- 23/10: "sarebbe carino… così Echo può dire dove siamo stati".
- 24/10: Echo records the visits itself ("se Echo può registrare le visite sarebbe comodo").

## Calls made by Claude (check these)

- Off by default; an explicit screen before asking "Always"; 90 days of visits; never through MCP;
  deletable one by one, by day, all.
- A visit counts from 10 minutes in one place.
- The place's name: Apple's (MapKit/CLGeocoder) on iPhone when there is one, else the address; Android
  the geocoder's address.
- Visits upload like segments (batched, on any network unless the user chose Wi-Fi only).
- Memory answers get a "Places" section for the period the question names, and a conversation's
  context carries its place.

## Left to the builder

- The Android route for stays (interval, accuracy, how points become visits, phone or server side).
- How visits and conversations are joined (time overlap, the threshold) and shown in the app.
- The exact copy of the opt-in screen; evals for place questions.
