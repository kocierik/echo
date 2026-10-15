# Echo — Roadmap

> Aggiornata al 15/10/2026. Stato dettagliato, bug noti e prossimi passi: [PROJECT-STATUS.md](PROJECT-STATUS.md).
> Il piano nasce dal confronto con i concorrenti (Omi, Bee, Plaud, Limitless, occhiali con fotocamera) del
> 15/10/2026: prima non perdere niente, poi sfruttare ciò che solo Echo ha (fotocamera, voci, server tuo),
> poi far arrivare Echo da te e rendere l'app immediata.

## Piano

Ogni fase si progetta e si costruisce a sé; l'ordine è concordato.

### Fase 0 — Prerequisiti (utente)
- [ ] Sostituire la chiave API di esempio (`make create-key`, poi `make revoke-example-key`)
- [ ] Caricare il firmware, reinstallare l'app, registrare la propria voce (Settings → Voices)
- [ ] Una giornata d'uso vero: i dati servono per misure e tarature della Fase 1

### Fase 1 — Non perdere niente (firmware)
- [x] Buffer offline da ~64 s a ~13 minuti di parlato, con la PSRAM libera (8 MB); in Today "N min of speech to sync"
- [x] Pulsante fisico (D1/GPIO2 → GND): pressione breve = foto con notifica, lunga = muto/riattiva
- [ ] Tarature sui dati reali: tempi dei comandi vocali (scatto anticipato se serve), soglie delle voci,
      risoluzione delle foto

### Fase 2 — Fotocamera più utile
- [x] Le foto generano task ed eventi (estrazione delle entità sulla descrizione)
- [x] Foto nel dettaglio della conversazione (riepilogo e transcript) e in Memories (📷 N)
- [x] Biglietto da visita → persona in People con ruolo, azienda, email, telefono (contatto Google: a richiesta in chat)

### Fase 3 — Echo viene da te
- [x] Riepilogo serale (spento di default, attivabile in Settings → Notifications)
- [x] Promesse da mantenere: riconosciute nell'estrazione, sezione "Promises" in Today, notifica la mattina
      della scadenza
- [x] Briefing 10 minuti prima di un incontro, solo se c'è qualcosa da sapere sulla persona (apre la sua pagina)
- Deciso: notifiche programmate dal telefono a ogni risveglio (niente account sviluppatore a pagamento); al
  massimo 3 al giorno, mai tra le 22 e le 8

### Fase 4 — Esperienza d'uso
- [x] App veloce anche offline: copia locale delle letture (cancellata al logout), Today si apre dalla copia,
      striscia "Offline · updated 14:32"
- [x] "Echo sta lavorando…" in Today per i comandi vocali e le foto in arrivo, finché arriva la risposta
- [x] Far scoprire le funzioni: pagina "What Echo can do" con esempi da toccare, suggerimenti una volta sola
      (registra la tua voce, nomina chi parla), riga "Hold 🎙 to talk · 📷" in Ask
- [x] Live Activity (iOS 16.1+): schermata di blocco e Dynamic Island con stato (ascolta/muto/offline),
      batteria e minuti in attesa di sync; aggiornata dall'app, senza push. Spegnibile in Settings → Notifications
- [x] Condividere una conversazione (testo/Markdown); export di tutti i dati in JSON (Settings → Privacy)

### Fase 6 — Piattaforma
- [x] Aggiornamento del firmware senza cavo: `make firmware-release` → server → app → Bluetooth, con
      controllo SHA-256 e ritorno automatico alla versione precedente ([ADR 0009](adr/0009-firmware-updates-over-ble.md))
- [ ] microSD (solo se il buffer attuale risulta corto nell'uso reale)
- [ ] Promemoria e Calendario Apple nativi (senza passare da Composio)
- [ ] Test di 2 ore della core beta su iPhone ([checklist](BETA-GATE-CHECKLIST.md)) e test batteria di 12 ore

## Già fatto

- **Catena di base:** wearable ESP32-S3 (VAD, ADPCM, buffer PSRAM, relay BLE con conferma di upload,
  ADR 0006), backend FastAPI + worker (STT, entità, conversazioni, RAG), Postgres + pgvector, CI completa.
- **Memoria:** riassunti per conversazione, giornalieri e **settimanali**; persone note nell'estrazione;
  deduplicazione; date relative; **ricerca per persona** ("cosa ha detto Marco?"); People con conversazioni e
  task; correzione dei transcript con rianalisi.
- **Voci:** impronte vocali sul server, la tua voce registrata, nomi assegnati dal transcript, "Marco?" quando
  incerto (ADR 0008).
- **Fotocamera:** foto a comando ("Echo, cos'è questo?" o pulsante 📷), risposta in chat e descrizione in
  memoria, nessuna foto conservata sul dispositivo (ADR 0007).
- **Azioni:** Gmail, Calendar, Slack, Telegram, Todoist, Notion via Composio, conferma per ciò che tocca altri,
  registro; richieste vocali "Echo, …".
- **App:** Today / Memories / Tasks / Ask, chat in streaming con fonti, batteria del dispositivo, onboarding con
  pairing rimandabile, tema chiaro/scuro.
- **Modelli:** `gpt-6-luna` per ogni ruolo (analisi, chat, agente, instradamento, visione), Deepgram Nova-3,
  banco di prova per sceglierli ([MODEL-EVALUATION.md](MODEL-EVALUATION.md)).

## Più avanti

- Firmware: wake word sul dispositivo, risparmio energetico (light sleep tra i frame VAD), feedback aptico.
- Memoria: filtro per tipo di entità ("i miei task aperti con Marco"), raggruppamento per argomento.
- Provider alternativi e locali: Whisper/LLM/embedding self-hosted, Claude, Gemini.
- Deploy: Compose di produzione (TLS, backup), script per VPS.
- Modalità consenso basata sulla voce (testo completo solo per te e per le voci registrate): utile
  quando Echo avrà altri utenti o con le voci collaudate nell'uso reale.
- Multi-utente: registrazione, isolamento dei dati, più dispositivi, plugin di terze parti.
