# L'app sull'iPhone senza un Mac

Un Mac di GitHub compila l'app senza firma; sull'iPhone [SideStore](https://sidestore.io) la firma con il
tuo Apple ID gratuito. La firma dura 7 giorni e SideStore la rinnova. Serve un computer (anche Linux) solo
la prima volta, per installare SideStore.

## 1. Compilare l'app

1. Su GitHub: **Actions → iOS build (unsigned) → Run workflow** (ramo `main`).
2. A fine esecuzione (10–20 minuti) scarica **Echo-unsigned-ipa** dagli *Artifacts* della run: è uno zip che
   contiene `Echo-unsigned.ipa`. Resta disponibile 14 giorni.

Con il repository privato i minuti delle macchine macOS contano 10 volte nel piano gratuito di GitHub (2.000
minuti al mese): circa una decina di build al mese.

## 2. Installare SideStore (una volta, dal PC Linux)

1. Sul PC: `sudo apt install usbmuxd libimobiledevice-utils`, poi scarica [iloader](https://github.com/nab138/iloader)
   (AppImage o .deb, dalla pagina *Releases*).
2. Collega l'iPhone con il cavo e tocca **Autorizza** sul telefono.
3. Sull'iPhone: **Impostazioni → Privacy e sicurezza → Modalità sviluppatore** attiva (il telefono si riavvia).
4. In iloader: accedi con il tuo Apple ID e scegli l'installazione di SideStore. Segui il
   [wiki di iloader](https://github.com/nab138/iloader/wiki), che è aggiornato per l'iOS attuale.
5. Sull'iPhone: **Impostazioni → Generali → VPN e gestione dispositivi**, autorizza il tuo Apple ID.
6. Installa **LocalDevVPN** dall'App Store: SideStore lo usa per firmare e rinnovare senza computer.

## 3. Installare Echo

1. Porta `Echo-unsigned.ipa` sull'iPhone: scarica lo zip dalla pagina della run in Safari (con il tuo account
   GitHub) e aprilo in File, oppure passalo da iCloud Drive o Google Drive.
2. In SideStore, con LocalDevVPN acceso: **My Apps → +** e scegli il file `.ipa`.
3. Se c'è ancora la vecchia Echo installata da Xcode, cancellala prima: la memoria è sul server, non sul telefono.
4. Apri Echo e **accedi** con il tuo account (non registrarti: un account nuovo parte vuoto). Se il dispositivo
   non si collega, in Profile → Echo usa *Forget device* e abbinalo di nuovo.

## Ogni 7 giorni

La firma scade dopo 7 giorni: prima della scadenza apri SideStore con LocalDevVPN acceso e tocca **Refresh All**
(SideStore può anche farlo da solo in background, se lo attivi nelle sue impostazioni). Se scade, l'app non si apre finché non la rinnovi; i dati restano.

Per una versione nuova: rilancia il workflow e installa il nuovo `.ipa` da SideStore come sopra.

## Limiti dell'Apple ID gratuito

- Al massimo 3 app firmate così, SideStore compreso.
- Al massimo 10 identificativi di app a settimana: Echo ne usa 2 (l'app e la sua Live Activity).
- La Live Activity potrebbe non comparire, perché SideStore firma di nuovo anche lei; Bluetooth, notifiche
  locali, Promemoria e Calendario non dipendono dalla firma.

Senza questi limiti c'è l'Apple Developer Program (99 $ l'anno): build su TestFlight valide 90 giorni,
installate dall'app TestFlight, senza computer né rinnovi.
