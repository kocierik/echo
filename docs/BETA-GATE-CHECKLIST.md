# Core beta — checklist del test di 2 ore

Gate della [spec core beta](superpowers/specs/2026-10-01-core-beta-design.md#success-criteria):
una sola build **release iOS installata direttamente** (niente debugger, niente cavo USB)
deve superare 2 ore continue di uso reale. Il force-quit dell'app è escluso.

Compila una copia di questo file per ogni tentativo (es. `docs/beta-runs/2026-10-20.md`).

## Prima di iniziare

| | Valore |
|---|---|
| Data / ora inizio | |
| Commit backend | |
| Commit app / build iOS | |
| Versione firmware (`DEVICE_INFO`) | |
| iPhone / versione iOS | |
| Rete backend (LAN / tunnel) | |

- [ ] Backend aggiornato: `alembic upgrade head` eseguito, worker attivo (`/health` → `ok`, code vuote).
- [ ] Dead letter queue vuota in `admin.html`.
- [ ] Wearable carico, pairing fatto dall'onboarding, stato **Listening** in Today.
- [ ] Notifiche permesse; impostazione Wi-Fi only **disattivata** (salvo test dedicato).
- [ ] Annotato il numero di Segment già presenti (`GET /api/stats` → `segments`).

## Scenari (durante le 2 ore)

Per ogni riga segna l'ora, l'esito e cosa hai visto in app (stato, banner, notifiche).

| # | Scenario | Atteso | Ora | Esito |
|---|---|---|---|---|
| 1 | App in primo piano, parlare 5 min | Segment caricati, trascrizioni in Transcripts | | |
| 2 | App in background (home), parlare 10 min | Upload continua; nessuna notifica di errore | | |
| 3 | Schermo bloccato, parlare 15 min | Upload continua; trascrizioni presenti allo sblocco | | |
| 4 | Bluetooth off 1 min → on | Stato Bluetooth off → reconnecting → listening senza toccare nulla | | |
| 5 | Allontanarsi dal wearable > 2 min, poi tornare | Notifica "disconnected" dopo 2 min, annullata al rientro; Segment registrati nel frattempo caricati | | |
| 6 | Backend spento 5 min mentre si parla, poi riacceso | Il wearable **non** scarta i Segment (nessun `UPLOAD_OK`); caricati dopo il ripristino; notifica upload ripetuti falliti | | |
| 7 | Mute da Today | Stato Muted; nessun nuovo Segment mentre si parla | | |
| 8 | Mute + disconnessione + riavvio wearable | Al rientro resta **muted**; Resume riprende l'ascolto | | |
| 9 | Overflow PSRAM (backend spento a lungo mentre si parla) | Avviso con numero di Segment persi, persi i più vecchi; notifica se in background | | |
| 10 | iOS termina l'app in background (es. molte app aperte) | Restore BLE: relay riprende senza aprire l'app | | |
| 11 | Correzione di una trascrizione e dello speaker | Testo aggiornato; rianalisi completata; **nessun** evento/task/messaggio duplicato nelle integrazioni | | |
| 12 | Chat in Ask, chiudere, riaprire dopo > 30 min dallo storico | Storico completo; la domanda di follow-up usa il contesto | | |
| 13 | Eliminare una conversazione | Sparisce da Transcripts; audio rimosso (`/api/stats` → storage) | | |

## Alla fine

- [ ] **≥ 20 Segment accettati** nel periodo (`segments` finale − iniziale): ____
- [ ] Nessun duplicato logico (stesso audio due volte in Transcripts).
- [ ] Nessuna perdita silenziosa: ogni perdita è stata segnalata (scenario 9) — Segment persi totali: ____
- [ ] Nessun crash dell'app; nessun caricamento infinito (spinner che non finisce).
- [ ] Dead letter queue: voci presenti ____ (ognuna spiegata).
- [ ] Retention: i file audio dei Segment completati spariscono dopo 24 h (verificare il giorno dopo).

## Esito

- [ ] **Superato** — tutte le righe ok
- [ ] **Non superato** — problemi trovati (uno per riga, con ora e log/screenshot):

1.
