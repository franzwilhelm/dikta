# Teknisk oversikt

## NB-Whisper-modeller

Medium er standard. Innstillingene tilbyr også Large, som lastes ned av appen i
bakgrunnen med URLSession. SHA-256 beregnes utenfor hovedtråden før filen gjøres
tilgjengelig. Fremdrift, avbryt og forsøk på nytt vises i innstillingene.
Appen må være åpen under nedlastingen; en avbrutt nedlasting starter på nytt ved
nytt forsøk. Medium brukes mens den valgte modellen mangler. Hver økt låser sitt
modellvalg ved start; en ferdig nedlasting bytter aldri motor midt i opptaket.
Modellen i minnet erstattes ved neste økt, uten å holde begge lastet samtidig.

Large bruker fullpresisjonsfilen på 3 095 033 483 byte fra
[Nasjonalbiblioteket](https://huggingface.co/NbAiLab/nb-whisper-large/blob/8c6249fdeeb4dcd05e5735a4c39640607eb6e4ac/ggml-model.bin),
revisjon `8c6249fdeeb4dcd05e5735a4c39640607eb6e4ac`, SHA-256
`0f2f66f22e11a7c7da3c582d8e5c89cb2c0011753ba9c7c9731e320a4ba33e76`.

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
open ~/Applications/Dikta.app
```

Bygging krever Swift Command Line Tools, CMake og Git. Første installasjon laster ned ca. 1,53 GB modeller og bygger whisper.cpp. Avslutt en kjørende Dikta før reinstallasjon. Skriptet bygger release, pakker ressursene, signerer lokalt med ad hoc-signatur og installerer i `~/Applications`. Appidentiteten er `no.franzvonderlippe.Diktat`, med et fast designated requirement for lokale oppdateringer. Ingen Developer ID eller notarisering er inkludert. macOS kan kreve ny tilgang etter endringer i installasjon eller signering.

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

Innstillinger og nedlastede modeller lagres permanent. Dikta skriver ikke
taleinnhold til systemlogger. Utklippstavlen administreres av macOS og kan inngå
i systemets synkronisering eller en utklippstavle-app. Begge motorene kjører lokalt.

API-grunnlag: [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber), [ferdigstilling av lydstrøm](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput()), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).

## Manuell akseptanse

Se [VERIFICATION.md](../VERIFICATION.md) for hva som er kontrollert og hva som må prøves med tale og tilgangene på Mac-en.
