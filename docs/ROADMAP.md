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
- [ ] Buffer offline da ~64 s a ~13 minuti di parlato, con la PSRAM libera (8 MB)
- [ ] Pulsante fisico: pressione breve = foto, lunga = muto
- [ ] Tarature sui dati reali: tempi dei comandi vocali (scatto anticipato se serve), soglie delle voci,
      risoluzione delle foto

### Fase 2 — Fotocamera più utile
- [ ] Le foto generano task ed eventi (estrazione delle entità sulla descrizione)
- [ ] Foto nel dettaglio della conversazione e in Memories
- [ ] Biglietto da visita → persona in People (e contatto Google, se collegato)

### Fase 3 — Echo viene da te
- [ ] Riepilogo serale
- [ ] Promesse da mantenere ("ti mando il preventivo" → promemoria con la frase d'origine)
- [ ] Briefing prima di un incontro (calendario + persone: ultima conversazione, task aperti, promesse)
- Da decidere: notifiche push di Apple (orario preciso, serve l'account sviluppatore) o programmate dal
  telefono (meno precise)

### Fase 4 — Esperienza d'uso
- [ ] App veloce anche offline (copia locale dei dati)
- [ ] "Echo sta lavorando alla tua richiesta…" in Today per i comandi vocali
- [ ] Far scoprire le funzioni: suggerimenti la prima volta, pagina "Cosa può fare Echo"
- [ ] Live Activity "Echo sta ascoltando" (con batteria) e widget iOS
- [ ] Condividere ed esportare una conversazione; export di tutti i dati

### Fase 5 — La privacy come vantaggio
- [ ] Modalità consenso basata sulla voce: testo completo solo per te e per le persone registrate,
      un riassunto anonimo (o niente) per le voci sconosciute

### Fase 6 — Piattaforma
- [ ] Aggiornamento del firmware senza cavo (OTA) e microSD
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
- Multi-utente: registrazione, isolamento dei dati, più dispositivi, plugin di terze parti.
