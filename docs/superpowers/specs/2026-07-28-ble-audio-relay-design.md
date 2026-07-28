% BLE audio relay — Specifica di design (2026-07-28)

Sommario
-------
Questa specifica descrive l'architettura, i protocolli e le scelte tecniche per il "BLE audio relay": un gateway che riceve pacchetti audio via BLE da dispositivi embeded, li ricostruisce, effettua buffering/jitter smoothing e li inoltra a un endpoint locale o remoto.

Architettura ad alto livello
---------------------------
- Ruoli:
  - Endpoint device: cattura audio, codifica (ADPCM), frammenta e invia via BLE.
  - Relay/Gateway: centralizza più connessioni BLE, mantiene buffer per ciascuna sessione, applica jitter buffering e inoltra stream (via websocket/HTTP/gRPC) al backend.
  - Backend (opzionale): riceve stream/frames, esegue trascrizione/analisi.

Formati e protocolli
--------------------
- Audio codec: ADPCM (già usato nel repo) come payload primario.
- Framing BLE: ogni frame contiene header minimale:
  - session_id (32 bit)
  - sequence_number (32 bit)
  - timestamp (64 bit, ms unix)
  - flags (8 bit: e.g., start/end, keyframe)
  - payload_length (16 bit)
  - payload (ADPCM bytes)

- Rationing/frammentazione: BLE ATT MTU limita payload; i frame possono essere suddivisi su più pacchetti con un campo fragment_id e total_fragments.

Buffering, latenza e jitter
--------------------------
- Jitter buffer per sessione con dimensione configurabile (p.es. 50–250 ms). Modalità adattiva: se throughput basso aumentare buffering, se latenza critica diminuirlo.
- Politica di drop: oldest-first per evitare ritardi eccessivi; segnala al backend eventi di perdita.

Gestione connessioni e resilienza
--------------------------------
- Riconnessioni: quando un device si riattacca, usare `session_id` + `sequence_number` per ricostruire lo stato. Offrire finestra di ricomposizione (p.es. 5 secondi) per frame persi.
- Acknowledgement: opzionale ack a livello di frame per dati critici; per risparmiare energia usare NACK su lacune rilevate.

Inoltro e API tra relay e backend
---------------------------------
- Transport: WebSocket con frammentazione di frame, o gRPC streaming per reti affidabili. Protocollo: incapsulare gli stessi campi header + payload.
- Endpoint REST per controllo sessione: start/stop, health, metrics.

Memoria e ottimizzazioni (PSRAM)
--------------------------------
- Allocazione buffer circolare in PSRAM per sessione. Limite per sessione configurabile (p.es. 64–256 KB).
- Evitare copie inutili: zero-copy se possibile tra BLE stack e buffer di inoltro.

Considerazioni energetiche
-------------------------
- Minimizzare wake-ups: batch degli invii verso relay quando possibile.
- Modalità low-power: device può inviare solo frame chiave e delegare audio continui al relay se disponibile.

Test e validazione
-------------------
- Test unitari per frammentazione/ricostruzione.
- Test integrati con `simulator/adpcm_encode.py` per generare carichi realistici.
- Misure: latenza P50/P90, percentuale di frame ricostruiti correttamente, uso memoria per sessione.

Metriche e observability
------------------------
- Counters: frames_received, frames_dropped, sessions_active, retransmits
- Histogram: latency_ms
- Traces: session lifecycle (start/connect/disconnect/recover)

Interoperabilità e future estensioni
----------------------------------
- Supportare altri codec (Opus) in future iterazioni: negoziazione codec in header di sessione.
- Persistenza temporanea su disco per replay su reconnect (opzionale)

Esempio di flusso (semplice)
---------------------------
1. Device invia frame 1..N via BLE con `session_id` S.
2. Relay riceve, ricompone frammenti, appende a jitter buffer.
3. Client consumer pull/stream dal relay via WebSocket; relay manda i frame ricostruiti.
4. Backend elabora (opzionale) e risponde con ACK/command.

Decisioni aperte / trade-offs
-----------------------------
- Ack vs no-ack: ack aumenta robustezza ma anche latenza e consumo.
- Buffering dimensione fissa vs adattiva: adattiva migliora esperienza ma è più complessa.

Checklist di consegna per prototipo
----------------------------------
- [ ] Implementare header/frame parser
- [ ] Jitter buffer per sessione
- [ ] Forwarder WebSocket streaming
- [ ] Test con simulator e misure di latenza
# BLE Audio Relay Design

## Goal

Replace the wearable's direct Wi-Fi transport with a BLE-only relay through the
Echo Flutter app. The MVP supports Android and iOS while the app is open and
must not remove a Segment from the wearable buffer until the backend accepts it.

## Scope

Included:

- BLE-only firmware transport for ADPCM Segments.
- Android and iOS foreground relay.
- Packet sequencing, integrity validation, acknowledgements, retransmission,
  backend upload, and visible connection/error state.
- Unit-testable protocol and packet assembly components.

Excluded:

- Background or terminated-app relay.
- BLE bonding, pairing, or application-layer encryption.
- Persistence across wearable power loss.
- Wi-Fi fallback.
- OTA firmware updates.

## Architecture

The wearable always stores each completed Segment in the existing PSRAM ring
buffer. When the app is connected and ready, the wearable transfers the oldest
Segment over GATT. The app validates and reassembles it, uploads it through the
existing multipart `/api/segments` endpoint, and sends `UPLOAD_OK` only after an
HTTP 201 response. The wearable calls `dequeue()` only after receiving that
command for the active Segment.

If the connection drops or either side detects invalid transfer state, the
active transfer is discarded but the PSRAM entry remains. The oldest Segment is
restarted from its first frame after reconnection. Backend idempotency protects
against a connection loss after HTTP 201 but before `UPLOAD_OK` reaches the
wearable.

PSRAM is volatile. Segments not acknowledged before device power loss are lost.

## GATT Contract

The firmware advertises as `Echo Wearable` and includes the existing service
UUID:

- Service: `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
- Audio characteristic: `beb5483e-36e1-4688-b7f5-ea07361b26a8`
- Control characteristic: `beb5483e-36e1-4688-b7f5-ea07361b26a9`

The audio characteristic sends firmware-to-app notifications. The control
characteristic accepts app-to-firmware writes and exposes firmware status
notifications. Multi-byte integers are unsigned little-endian.

### Audio Frames

Every frame starts with a one-byte type and a four-byte `segment_id`.

`SEGMENT_START` (`0x01`):

- protocol version: 1 byte, initially `1`
- total ADPCM length: 4 bytes
- duration milliseconds: 4 bytes
- total chunk count: 2 bytes
- ADPCM CRC32: 4 bytes

`SEGMENT_METADATA` (`0x02`):

- recorded-at Unix seconds: 8 bytes
- silence-before milliseconds: 4 bytes
- average audio energy: 2 bytes

`SEGMENT_DATA` (`0x03`):

- sequence number: 2 bytes, starting at zero
- ADPCM payload: up to negotiated MTU minus protocol and ATT overhead

The firmware sends `SEGMENT_START`, `SEGMENT_METADATA`, then numbered data
frames. It sends a bounded window of data frames and waits for a control ACK
before sending the next window. The initial window size is eight frames.

### Control Frames

`READY` (`0x10`): app is subscribed and ready to receive.

`ACK_WINDOW` (`0x11`): contains `segment_id` and highest contiguous sequence
received. The firmware advances only when the ID and sequence match its active
window.

`RESTART_SEGMENT` (`0x12`): contains `segment_id`. The firmware restarts that
Segment from `SEGMENT_START` if it is still the oldest buffered entry.

`UPLOAD_OK` (`0x13`): contains `segment_id`. The firmware dequeues only when it
matches the active oldest Segment.

`SET_TIME` (`0x14`): contains current Unix milliseconds and current app timezone
offset. The app sends it before `READY`. The firmware combines this wall-clock
anchor with its monotonic `millis()` value so Segments recorded before or after
connection receive a stable UTC timestamp without Wi-Fi or NTP. A power cycle
resets the anchor; Segments recorded before the first app connection retain their
capture-time `millis()` value and are resolved when the first `SET_TIME` arrives.

`DEVICE_STATUS` (`0x20`): firmware-to-app notification containing buffer count,
buffer bytes used, and an error code. It is emitted after connection, store,
dequeue, and buffer-full events.

Unknown frame types, protocol versions, Segment IDs, and out-of-range sequence
numbers reset only the active transfer. They never dequeue buffered data.

## Firmware Components

`ble_protocol.h` owns frame constants, packed field encoding/decoding, and CRC32.
It has no Arduino BLE dependency and is unit-testable.

`ble_transport.h` owns NimBLE initialization, advertising, connection state,
MTU-aware packet sizing, the transfer window, control writes, timeouts, and
status notifications. Only one Segment can be in flight.

`main.ino` no longer initializes Wi-Fi, NTP, or `HttpSender`. It initializes the
BLE transport, stores every finalized Segment in PSRAM, and services the oldest
buffered Segment when a subscribed app is ready. Recording remains active while
transfers occur; PSRAM decouples capture from relay.

The existing `PSRAMBuffer` remains the owner of buffered Segment bytes. It gains
the metadata or identifiers required by the protocol and must explicitly track
wrap boundaries so FIFO reads remain valid when a write wraps to offset zero.
`dequeue()` remains the sole removal operation.

The XIAO ESP32-S3 board must use its official 8 MB partition default. The invalid
`default_16MB.csv` override stays removed from `platformio.ini`.

## Mobile Components

`ble_packet_assembler.dart` owns protocol parsing, sequence tracking, metadata,
CRC validation, and immutable completed-Segment output. It has no FlutterBlue or
HTTP dependency.

`BleService` owns scan, connect, service discovery, subscriptions, control
writes, upload retries, and reconnect behavior. It requests the largest
supported MTU but accepts the negotiated value. It sends `SET_TIME` before
`READY`. A failed upload never sends `UPLOAD_OK`. A completed Segment remains
recoverable from the wearable and can be requested again after reconnect.

`MainShell` owns one `BleService` instance for the configured app session. The
service survives tab changes and is disposed when the shell is disposed. The app
attempts reconnection while it remains in the foreground after the user has
initiated the first connection.

`BleIndicator` exposes disconnected, scanning, connecting, connected,
transferring, and error states. Tapping it initiates scan/connect or opens
current transfer/error details. Bluetooth-off, permission denial, backend
failure, and buffer-full errors are visible rather than swallowed.

Android permissions are adjusted for pre-Android-12 and Android-12+ behavior.
iOS keeps Bluetooth usage descriptions and does not enable background modes in
this MVP.

## Failure Semantics

- Missing or out-of-order data: app sends `RESTART_SEGMENT`.
- CRC mismatch: app discards assembled bytes and sends `RESTART_SEGMENT`.
- ACK timeout: firmware restarts the active transfer without dequeueing.
- BLE disconnect: both sides reset transfer state; PSRAM data remains.
- HTTP timeout, exception, non-201, or missing API key: no `UPLOAD_OK`.
- Disconnect after HTTP 201: retransmission is accepted by backend idempotency,
  then acknowledged normally.
- PSRAM full: newest Segment cannot be stored, serial logging and
  `DEVICE_STATUS` report the loss; existing buffered Segments remain intact.

## Verification

Firmware protocol tests cover frame byte order, maximum field values, CRC32,
invalid frame lengths, time-anchor conversion, and control frame decoding.
PSRAM tests cover multiple FIFO entries, wrap-around, full-buffer rejection, and
dequeue after wrap. The complete firmware must compile for
`seeed_xiao_esp32s3` using the 8 MB board default.

Dart tests cover normal assembly, missing sequence, duplicate sequence, wrong
Segment ID, CRC mismatch, reset, and metadata preservation. Service tests cover
HTTP 201 followed by `UPLOAD_OK`, HTTP failure without acknowledgement, and
reconnection restart.

Android and iOS static analysis/builds must succeed on the development machine.

Hardware acceptance tests:

1. Record and relay a normal Segment.
2. Disable Bluetooth halfway through transfer, reconnect, and receive the whole
   Segment.
3. Stop the backend, record a Segment, restore the backend, and upload it without
   dequeueing early.
4. Disconnect immediately after backend acceptance and verify logical
   idempotency on retransmission.
5. Queue multiple Segments while disconnected and verify FIFO delivery.

The core invariant is: the wearable never calls `dequeue()` for a Segment before
receiving matching `UPLOAD_OK` after backend HTTP 201.