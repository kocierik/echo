# Salute in Echo, con Comandi rapidi

L'app Echo installata con SideStore non può leggere Salute: Apple concede quel permesso solo alle app
firmate con l'Apple Developer Program a pagamento. Lo fa al suo posto **Comandi rapidi**, l'app di Apple:
un'automazione ogni sera legge sonno, passi, distanza ed esercizio del giorno e li manda a Echo. Echo li
usa nelle risposte ("come ho dormito questa settimana?") e nei grafici.

La chiave usata dal comando rapido può **solo** inviare questi dati: non legge la tua memoria né altro.
Si revoca da Profile → Health → *Delete health data* o da Profile → Devices.

## 1. La chiave

In Echo: **Profile → Health → Create the key for Shortcuts**. Copia l'indirizzo e la chiave: la chiave si
vede una volta sola (crearne una nuova disattiva la vecchia).

## 2. Il comando rapido

In **Comandi rapidi → Automazione → +** scegli **Ora del giorno**, alle **22:30**, **Ogni giorno**, ed
**Esegui immediatamente** (così non chiede conferma). Poi **Nuovo comando rapido vuoto** e aggiungi
queste azioni nell'ordine (i nomi possono variare un po' con la versione di iOS):

**Sonno di stanotte**
1. **Trova campioni di Salute** · Tipo: *Analisi del sonno* · filtri: *Data di fine* **è oggi**,
   *Valore* **non è** *A letto*, *Valore* **non è** *Sveglio*.
2. **Ottieni dettagli dei campioni di Salute** · *Durata*.
3. **Calcola statistiche** · *Somma* → rinomina il risultato **Sonno** (tieni premuto → Rinomina).

**Passi, distanza, esercizio di oggi** (per ognuno, due azioni):
4. **Trova campioni di Salute** · Tipo: *Passi* · *Data di inizio* **è oggi**.
5. **Calcola statistiche** · *Somma* → **Passi**.
6. Come sopra con *Distanza camminata + corsa* → **Distanza**.
7. Come sopra con *Minuti di esercizio* → **Esercizio**.

**La data**
8. **Data attuale**, poi **Formatta data** · formato *Personalizzato* `yyyy-MM-dd` → **Giorno**.

**L'invio**
9. **Ottieni contenuto dell'URL**
   - URL: l'indirizzo copiato da Echo (`https://…/api/health/day`)
   - Metodo: **POST**
   - Intestazioni: `X-API-Key` = la chiave copiata
   - Corpo della richiesta: **JSON**, con i campi
     `date` = Giorno, `sleep` = Sonno, `steps` = Passi, `distance` = Distanza,
     `exercise_minutes` = Esercizio
10. Facoltativo: **Mostra risultato**, solo per la prova (poi toglilo).

Tocca ▶︎ per provarlo: la risposta di Echo dice cosa ha capito, per esempio
`{"day": "2026-11-05", "sleep_minutes": 410, "steps": 8421, …}`. Lo vedi anche in Profile → Health.

## Note

- **Sonno doppio** (iPhone e Apple Watch registrano entrambi): se le ore risultano il doppio del vero,
  aggiungi al passo 1 il filtro *Sorgente* **è** il tuo Apple Watch.
- Il sonno può arrivare in ore, minuti o secondi: Echo lo capisce da solo. I numeri scritti all'italiana
  ("8.421", "5,1") vanno bene.
- Gli allenamenti sono facoltativi: con **Trova allenamenti** (oggi) puoi mandare un testo nel campo
  `workouts` (per esempio "Corsa 32 min, 5,1 km").
- Mandare di nuovo lo stesso giorno aggiorna solo i campi inviati.
- Echo usa gli ultimi 14 giorni. *Delete health data* cancella tutto e disattiva la chiave.
