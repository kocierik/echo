# Echo — Cosa fa oggi

> Resoconto al 29/10/2026 di tutto ciò che è implementato e su `main`. Quello che manca è in
> [ROADMAP.md](ROADMAP.md); i dettagli tecnici e i problemi aperti in [PROJECT-STATUS.md](PROJECT-STATUS.md).

## Il dispositivo

- Ascolta da solo quando qualcuno parla (niente wake word) e tiene fino a ~13 minuti di parlato in memoria
  quando il telefono non c'è; con una microSD il resto va sulla scheda (circa 36 ore per GB) invece di andare
  perso. Today mostra quanti minuti aspettano di essere inviati. Con la scheda il LED resta spento.
- Invia l'audio al telefono via Bluetooth cifrato, con conferma: niente si cancella prima che il server l'abbia.
- Pulsante: pressione breve = foto, lunga = muto/riattiva.
- Fotocamera su richiesta: una foto alla volta, mai tenuta sul dispositivo.
- Si aggiorna senza cavo: il firmware pubblicato sul server arriva via Bluetooth, controllato, e se la nuova
  versione non si collega torna da solo alla precedente. Firmware attuale 0.6.0.

## Ricordare

- Trascrizione (Deepgram o OpenAI), divisione in conversazioni, titolo, riassunto ed emoji per ognuna.
- Dalle conversazioni: persone, promesse fatte da te (con la frase d'origine), eventi, idee, note.
- Date e orari relativi risolti ("giovedì alle 3" → la data giusta).
- Riassunto di ogni giorno e di ogni settimana.
- Trascrizione correggibile, con rianalisi della conversazione.
- Altre lingue sentite intorno (fino a 4, Profile → Language): riconosciute riga per riga, con "Translate"
  nella conversazione.

## Chiedere (Ask)

- Domande scritte o dettate (tieni premuto il pulsante Ask): Echo cerca nella memoria, prima tra le persone
  nominate, e risponde nella lingua della domanda, con le fonti che aprono la conversazione.
- Risposta che appare mentre viene scritta.
- Ricerca web per ciò che è attuale (meteo, notizie, prezzi), con i siti citati; 30 ricerche al giorno.
- Un unico thread con Echo (domande, richieste a voce, foto, risultati degli incarichi portati con "Ask
  about this"), più chat a parte con "New chat" e la cronologia.
- Ask → Routines: i risultati degli incarichi per giorno e per incarico.
- Ritentare non esegue due volte: la risposta già pronta torna indietro.

## Today

- In cima solo le azioni da confermare; poi le sezioni nell'ordine che scegli ("Edit Today" nasconde e sposta):
  - From your routines;
  - To do today;
  - Coming up today, con "Last time: …";
  - Your day (conversazioni e foto, quella in corso dal vivo);
  - People;
  - Saved;
  - Where you've been;
  - Earlier days.
- Funziona anche offline dalla copia sul telefono ("Offline · updated 14:32").
- Tasks: da fare per scadenza, completa con Annulla, "Not a task".

## Persone e voci

- People: ultima volta viste, ruolo e note, task ed eventi che le nominano, conversazioni, "Ask about".
- La tua voce registrata (Profile → Voices) e i nomi degli altri dati toccando una riga del trascritto; Echo
  poi scrive i nomi e chiede "Marco?" quando è incerto.
- Chi hai davanti: quando parla una voce che hai nominato, subito una notifica con le promesse nei due sensi e
  l'ultima conversazione.

## Fotocamera

- "Echo, cos'è questo?", il pulsante 📷 in Ask o quello del dispositivo; con il dispositivo non disponibile,
  la fotocamera del telefono.
- Risposta in chat con la miniatura e le azioni rapide: Translate, Ask more, Remind me (se la foto mostra una
  data).
- Descrizione nella memoria; foto agganciata alla conversazione in corso (lavagne, slide).
- Task ed eventi dalle foto (una locandina → un evento); biglietto da visita → persona in People.

## Saved e posti

- Saved: cose da ritrovare, non da fare. Esempi:
  - "ricordati dove ho parcheggiato" (un nuovo parcheggio sostituisce il vecchio);
  - "il passaporto è qui" (con la foto e il posto);
  - "salvami questo vino";
  - gli scontrini, e "quanto ho speso questa settimana?" fa la somma.
- Liste create da Echo da quello che dici; in Today → Saved e nei chip delle risposte.
- La posizione del telefono si legge solo quando chiedi di salvare qualcosa; indirizzo e link alla mappa.
- Places visited (Profile, spento di default, 90 giorni): i posti di oggi in Today e il posto di una
  conversazione.

## Agire sulle app

- Gmail, Google Calendar, Slack, Telegram, Todoist, Notion e altre app cercabili, via Composio (Profile → Apps).
- Promemoria e Calendario dell'iPhone senza Composio.
- Leggere e creare subito; mandare ad altri, modificare e cancellare aspettano il tuo **Confirm**.
- Registro di ogni azione (Profile → Activity).
- To-do: dalle conversazioni nascono solo le tue promesse esplicite; gli altri li chiedi tu ("segnami…").

## Richieste e risposte a voce

- "Ehi Echo, …" (anche "Echo, …", "Eco, …"): la risposta arriva nel thread in Ask, con una notifica.
- Spoken answers (Profile): il telefono legge la risposta ad alta voce, solo in cuffia o anche
  sull'altoparlante, anche a schermo bloccato; Echo non registra mentre il telefono parla.

## Incarichi (routine)

- "Ogni mattina alle 7 dimmi che tempo fa a Milano": giornalieri, feriali, settimanali o mensili, al massimo 10.
- Tre modi: dice sempre, solo se vale la condizione ("dimmi se piove"), solo le novità.
- Risultati in Today, in Ask → Routines e come notifica; pausa e cancellazione in Profile → Routines.

## Echo per te

- Istruzioni (Profile → Instructions): come deve risponderti, in ogni risposta in chat e a voce.
- About you (Profile → Memory):
  - frasi su di te usate in ogni risposta;
  - Echo ne propone dalle conversazioni e le usa solo se le tieni;
  - "ricordati che…" / "dimentica che…" le cambiano a voce.
- Documenti (Profile → Memory): PDF, Word, testo, Markdown cercati quando Echo risponde, nominando il
  documento; si tiene solo il testo.
- Assistenti (Profile → Assistants):
  - Lavoro, Dieta, Sonno o creati da zero;
  - ognuno con istruzioni, note che aggiorna da solo e documenti scelti;
  - una chat con loro in Ask, e gli incarichi creati nella loro chat girano come loro;
  - mai consigli medici.

## WhatsApp (in lettura, non ufficiale)

- Collega il tuo numero con un codice (Profile → WhatsApp) e chiedi "cosa mi ha scritto Marco?", anche negli
  incarichi.
- Solo chat private, nessun invio, messaggi solo in memoria per 7 giorni. WhatsApp può bloccare il numero.

## Notifiche ("Echo viene da te")

- Promesse da mantenere: la mattina della scadenza, e in Today.
- Briefing 10 minuti prima di un incontro, solo se c'è qualcosa da sapere sulla persona.
- Riepilogo serale (spento di default).
- Al massimo tre al giorno, mai tra le 22 e le 8, ognuna spegnibile.
- iPhone: Live Activity sulla schermata di blocco e nella Dynamic Island (ascolta, muto, offline, batteria,
  minuti da inviare).

## Account, privacy e dispositivi

- Primo avvio con benvenuto animato, accesso o registrazione con email e password, permessi, abbinamento.
- Una chiave per telefono, revocabile (Profile → Devices); password Argon2, tentativi limitati.
- Condividere una conversazione (testo o Markdown); export di tutti i tuoi dati in JSON (Profile → Privacy).
- Audio cancellato dopo l'elaborazione (24 h; 7 giorni se incompleto).
- Tema chiaro, scuro o di sistema.

## Fuori da Echo

- Server MCP: Claude, Cursor e altri assistenti leggono le tue memorie con una chiave di sola lettura
  ("Connect an assistant" in Profile → Devices). Sei strumenti: cerca, conversazione, persona, task, giorno,
  settimana.

## Sul server

- Costi per utente e per giorno (`make usage`: costo di un giorno e di un'ora di parlato).
- `gpt-6-luna` per ogni ruolo dei modelli, scelto con un banco di prova (MODEL-EVALUATION.md).
- Code con ritentativi, circuit breaker e coda degli errori; metriche Prometheus.
- App Android: si compila dallo stesso codice, non ancora provata con il dispositivo.
