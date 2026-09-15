# Diktat

<img src="Resources/AppIcon.png" width="128" alt="Diktat-ikon">

En liten menyfelt-app for lokal diktasjon på Apple Silicon og macOS 26.

## Installer med én kommando

På en Mac med **Apple Silicon og macOS 26 eller nyere**:

```sh
curl -fsSL https://github.com/franzwilhelm/dikta/releases/latest/download/install.sh | bash
```

Kommandoen laster ned den ferdigbygde appen til `~/Applications/Diktat.app`,
laster ned NB-Whisper Medium og Silero separat, kontrollerer SHA-256 og åpner appen.
Ingen Xcode, Homebrew eller sudo trengs. Modellene er ca. **1,53 GB** til sammen;
de følger ikke med apppakken. Avbrutte modellnedlastinger kan gjenopptas ved å
kjøre samme kommando igjen. Verifiserte modeller lastes ikke ned på nytt.

Første gang må du gi mikrofontilgang og aktivere Diktat under **Systeminnstillinger
→ Personvern og sikkerhet → Tilgjengelighet** for automatisk innliming og Escape.
Disse tillatelsene kan ikke gis av installasjonsskriptet.

**Oppdatering:** Avslutt Diktat og kjør samme kommando igjen. Innstillingene og
modellene beholdes. En eksisterende app erstattes først når alle filer er klare.

Appen er foreløpig ad hoc-signert, uten Developer ID/notarisering. På en annen Mac
kan Gatekeeper kreve «Åpne likevel» under Personvern og sikkerhet. Skriptet slår
ikke av Gatekeeper og fjerner ikke karantenemerking. Administrerte Mac-er kan
kreve godkjenning fra IT.

Utgivelseskommando og detaljene for vedlikehold finnes i [RELEASING.md](RELEASING.md).

## Bruk

Åpne `~/Applications/Diktat.app`. Innstillinger åpnes ved første oppstart. Mikrofonikonet i menyfeltet åpner menyen.

- **Start/stopp:** Ctrl + Option + mellomrom. Bølgeformen viser faktisk mikrofonaktivitet.
- **Avbryt:** Escape eller × på panelet. Ctrl + Option + Escape fungerer også. Forkaster økten uten å endre utklippstavlen. Diktat lytter etter Escape bare mens panelet vises. Global Escape krever Tilgjengelighet og kan også mottas av appen du skriver i.
- **Språk:** Norsk bokmål er standard. Velg English (US) i menyen før en økt.
- **Talemotor:** NB-Whisper Medium er standard. Velg «Mac-diktasjon» i innstillingene eller menyen for Apples motor.
- **Utdata:** «Lim inn automatisk» er på som standard. Slå av for bare kopiering.
- **Hurtigtaster:** Kan endres under «Innstillinger …».
- **Siste tekst:** «Kopier siste tekst» henter siste ferdige diktasjon frem til appen avsluttes.

Gi mikrofontilgang når macOS spør. Når automatisk innliming er på, ber Diktat om Tilgjengelighet ved oppstart og når valget slås på. Systeminnstillinger åpnes direkte; aktiver Diktat i listen. Hvis appen mangler, bruk + og velg `~/Applications/Diktat.app`. Diktats innstillinger viser tilgangsstatus og oppdaterer den mens vinduet er åpent. Uten denne tilgangen kopieres teksten, slik at du kan bruke ⌘V selv.

Det flytende panelet tar ikke tastaturfokus. Ved stopp brukes appen som da er aktiv. Hvis en annen app aktiveres under ferdigstilling, blir teksten bare kopiert, også hvis du bytter tilbake. Innliming venter inntil to sekunder på at modifikatortastene slippes. Appen sender ⌘V; målappen avgjør om innlimingen godtas.

Ved mikrofon- eller transkripsjonsfeil stopper økten. «Kopier tilgjengelig tekst» bevarer også foreløpig tekst for manuell bruk. Kopier denne før du starter en ny økt. Stillhet endrer ikke utklippstavlen. Mac-diktasjon har en ferdigstillingsgrense på 30 sekunder. Whisper kan bruke inntil 30 minutter på å tømme køen før tilgjengelig tekst tilbys manuelt.

## NB-Whisper Medium

Whisper behandler 20 sekunder ny lyd om gangen mens du snakker. Etter første
bolk tas fire sekunder fra forrige bolk med som overlapp. Modellen forhåndslastes ved appstart og beholdes i minnet mellom økter.
Mikrofonen venter ikke på modellasting; lyden settes i kø hvis modellen ennå
ikke er klar. Bolkene behandles etter tur. Panelet viser bare mikrofonens lydnivå;
Whisper-modus bruker ikke Apples talegjenkjenning eller løpende forhåndsvisning.
Ved stopp behandles køen og den siste resten før kopiering og eventuell innliming.
Ventetiden avhenger av hvor godt modellen holder følge med opptaket.

Skjøtingen fjerner like ordsekvenser i slutten av forrige resultat og starten av
neste, uten å skille mellom store og små bokstaver eller tegnsetting. Hvis modellen
transkriberer overlappen forskjellig, kan gjentakelser fortsatt forekomme. Den kan
også feiltolke eller utelate tale. Dette gir ikke garantert konsistens i lange samtaler.

Modellen er fullpresisjonsvarianten på 1 533 763 076 byte fra Nasjonalbiblioteket.
Den ligger i `~/Library/Application Support/Diktat/Models/nb-whisper-medium.bin`.
Silero VAD 6.2.0 (885 098 byte) lar appen hoppe over helt tause bolker; den klipper
ikke bort pauser eller ord inne i bolker med tale. Begge modeller kontrolleres med
SHA-256 ved installasjon og lastes bare ned når de mangler.

`whisper.cpp` v1.9.4 er statisk lenket direkte i appen med Metal gjennom CWhisper.
Norsk bruker språkkoden `no`, engelsk bruker `en`, med fire CPU-tråder og beam size 5.
Første oppstart kan også bruke tid på å kompilere Metal-kjerner, samtidig som
mikrofonen allerede kan ta opp. Modellen bruker minne også mellom opptak.

Ved stopp viser panelet tre pulserende prikker de første to sekundene. Deretter
vises prosent behandlet lyd, inkludert bolker som ble ferdige
under opptaket. Ferdige bolker vektes etter lydlengde; den aktive bolken bruker
Whispers egen fremdriftsrapportering. Verdien leses hvert 50 ms og tallendringer
animeres. Tiden alene flytter ikke prosenten. Whisper rapporterer grovt, så tallet
kan stå stille og deretter hoppe. Dette er ikke prosent av forventet ventetid.
100 % settes først når hele resultatet er klart. Mac-diktasjon gir ingen slik
fremdriftsrapportering og står på 0 % til ferdigstilling er fullført.
Tekstforhåndsvisning og løpende status er fjernet fra opptakspanelet for begge
motorene. Feil vises fortsatt med mulighet for kopiering.

Lyd og tekst holdes bare i minnet. Køen har plass til åtte ventende bolker; hvis
Whisper ikke holder følge og køen fylles, stopper opptaket med en feilmelding.
Allerede ferdig tekst beholdes for manuell kopiering. Avbryt stopper også aktiv
modellbehandling. Ingen lydfiler eller transkripsjonshistorikk lagres av appen;
minnebufferen overlever ikke et appkrasj.

Kilder og lisenser: [NB-Whisper Medium (Apache 2.0)](https://huggingface.co/NbAiLab/nb-whisper-medium),
[whisper.cpp (MIT)](https://github.com/ggml-org/whisper.cpp/tree/v1.9.4),
[Silero VAD](https://huggingface.co/ggml-org/whisper-vad).

## Bygg og installer

```sh
cd dikta
./scripts/prepare-whisper.sh
swift build
./scripts/install.sh
open ~/Applications/Diktat.app
```

Bygging krever Swift Command Line Tools, CMake og Git. Første installasjon laster ned ca. 1,53 GB modeller og bygger whisper.cpp. Avslutt en kjørende Diktat før reinstallasjon. Skriptet bygger release, pakker ressursene, signerer lokalt med ad hoc-signatur og installerer i `~/Applications`. Appidentiteten er `no.franzvonderlippe.Diktat`, med et fast designated requirement for lokale oppdateringer. Ingen Developer ID eller notarisering er inkludert. macOS kan kreve ny tilgang etter endringer i installasjon eller signering.

`DIKTAT_INSTALL_DIR` kan overstyre installasjonsmappen. `DIKTAT_SIGNING_IDENTITY` kan angi et eget signeringssertifikat.

KeyboardShortcuts 3.1.0 ligger i `Vendor/` med MIT-lisens og dokumenterte tilpasninger til Command Line Tools. Full Xcode er ikke nødvendig. Ingen automatiserte tester er opprettet.

## Oppbygning

- `SpeechSession.swift`: felles øktgrensesnitt og valg av talemotor.
- `AppleSpeechSession.swift`: Apples lokale talegjenkjenning og språkmodeller.
- `AudioFeed.swift`: mikrofonkonvertering og serialiserte lydcallbacker.
- `WhisperSession.swift`: lyd i bolker, kø og skjøting av tekst.
- `NBWhisper.swift` og `Sources/CWhisper/`: lokal modell, native kjøring og avbryt.
- `TranscriptBuffer.swift`: endelige og foreløpige Apple-segmenter.
- `SessionController.swift`: én aktiv økt, avbryt, tidsgrense og feilbehandling.
- `TextDelivery.swift`: utklippstavle, målapp og innliming.
- `RecordingPanel.swift`: flytende AppKit-panel med SwiftUI-innhold.
- `DiktatApp.swift`: menyfelt og innstillinger.

Innstillinger og nedlastede modeller lagres permanent. Diktat skriver ikke
taleinnhold til systemlogger. Utklippstavlen administreres av macOS og kan inngå
i systemets synkronisering eller en utklippstavle-app. Begge motorene kjører lokalt.

API-grunnlag: [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber), [ferdigstilling av lydstrøm](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput()), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).

## Manuell akseptanse

Se `VERIFICATION.md` for hva som er kontrollert og hva som må prøves med tale og tilgangene på Mac-en.
