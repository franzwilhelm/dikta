# Verifisering

## Miljø

- Apple Silicon, macOS 26.6.2.
- Apple Swift 6.3.3 via Command Line Tools.
- `DictationTranscriber.installedLocales` returnerte `en_US` og `nb_NO`.
- Ingen automatiserte tester er opprettet.

## Kontrollert 15. september 2026

- Debug-bygget fullførte uten advarsler.
- Release-bygget fullførte uten advarsler.
- Installasjonsskriptets shell-syntaks og begge plist-filene er validert.
- `~/Applications/Diktat.app` er installert med arm64-binær og lokal signatur.
- `codesign --verify --deep --strict` godkjente appen og dens faste designated requirement.
- Appen startet via `open`, og Diktat-prosessen fortsatte å kjøre.
- macOS rapporterte at «Diktat – innstillinger» var synlig etter første oppstart.
- Kildegjennomgang av øktstyring, ferdigstilling, avbryt og målappkontroll er utført.

Vindusskjermbilde kunne ikke hentes i denne økten, så visuell layout er ikke bekreftet. Mikrofonen ble ikke aktivert under den første verifiseringen; se krasjrettingen nedenfor.

## Må prøves interaktivt

Disse punktene er ikke bekreftet gjennom bygg eller kildekodegjennomgang:

- [ ] Gi mikrofontilgang og bekreft at panelet viser «Lytter».
- [ ] Norsk og engelsk: korte setninger, første/siste ord, tegnsetting og løpende rettelser uten duplikater.
- [ ] Flere minutters diktasjon på begge språk, også med nett frakoblet.
- [ ] Automatisk innliming og bare kopiering i TextEdit, nettleser og kodeeditor.
- [ ] Endre start/stopp-hurtigtasten og bruk den fra en annen app.
- [ ] Avbryt under klargjøring, opptak og ferdigstilling: eksisterende utklippstavle skal beholdes.
- [ ] Stillhet og raske tastetrykk: ingen overlappende økter eller uventet kopiering.
- [ ] Bytt app under ferdigstilling, også bort og tilbake: bare kopiering.
- [ ] Hold modifikatortaster inne etter stopp: bare kopiering etter ventefristen.
- [ ] Avslå mikrofontilgang: forklaring vises, intet opptak.
- [ ] Slå av Tilgjengelighet: ferdig tekst kopieres med forklaring.
- [ ] Koble fra/bytt mikrofon under opptak: opptak stopper, tilgjengelig tekst kan kopieres.
- [ ] «Kopier siste tekst» virker etter en avbrutt eller feilet senere økt.
- [ ] Panel vises over fullskjermsapper uten å ta tastaturfokus.

UI-automatisering via System Events er ikke tilgjengelig i denne økten (`-1743`, manglende Apple Events-tilgang). Ingen personverntillatelser er endret programmatisk.

## Rettet krasj ved opptaksstart, 15. september 2026

Krasjrapporten viste `EXC_BREAKPOINT` / `SIGTRAP` i lydcallbacken i
`SpeechSession.start`, på `RealtimeMessenger.mServiceQueue`. Callbacken arvet
`MainActor` fra opprettelsesstedet, mens AVAudioEngine kalte den fra en lydtråd.

Callbacken opprettes nå i `AudioFeed.makeTap()`, uten hovedtrådisolering.
Eksisterende lås beskytter fortsatt lydkonvertering og avslutning.

Med en midlertidig oppstartsinstrumentering som startet mikrofonen og deretter
avbrøt økten, ble følgende kontrollert mot den installerte release-appen:

- Før rettingen krasjet appen med exitkode 133.
- Etter rettingen var tilstanden `recording` etter fem sekunder og `idle`
  etter avbryt. Appen avsluttet normalt med exitkode 0.
- Økten ble forkastet uten å kopiere tekst eller sende innliming.
- Oppstartsinstrumenteringen ble fjernet før endelig installasjon.

Ingen testfiler ble opprettet. Taleinnhold, ferdigstilling og automatisk innliming
må fortsatt prøves interaktivt som beskrevet over.

## Automatisk forespørsel om Tilgjengelighet

- Diktat ber nå om Tilgjengelighet ved oppstart når automatisk innliming er på,
  og når valget aktiveres. Ved manglende tilgang åpnes personvernpanelet direkte.
- Innstillinger viser tilgangsstatus og oppdaterer den mens vinduet er åpent.
- Debug- og release-bygg fullførte, og oppdatert app er installert og signaturverifisert.
- Automatisk innliming er aktivert i brukerinnstillingene.
- macOS-loggen bekreftet at den kjørende appen fikk godkjent både
  `kTCCServiceAccessibility` og `kTCCServicePostEvent` etter oppstart.
  Innlimingens resultat i målappen er ikke visuelt kontrollert.


## NB-Whisper Medium integrert, 15. september 2026

- Lastet ned fullpresisjonsmodellen (1 533 763 076 byte), revisjon
  `0ed074d5985bd56ca4140159a9dbffbc3fb5117e`.
- SHA-256 verifisert mot modellutgiverens metadata:
  `f73141401d203ee77fc7ddf7bf97926a8a85fe85faa6066a6920e4815f48a73d`.
- Silero VAD 6.2.0 er lastet ned og kontrollsummen verifisert.
- whisper.cpp v1.9.4, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`,
  er bygget med Metal og statisk lenking. Hjelpeprogrammet har bare systembiblioteker
  som dynamiske avhengigheter, kontrollert med `otool -L`.
- Debug- og release-bygg fullførte. Hjelpeprogram og app er signert lokalt.
- En syntetisk norsk stemmefil på ca. 8,5 sekunder ble transkribert korrekt,
  inkludert «Nasjonalbiblioteket». Rapportert modellkjøring var ca. 5,3 sekunder;
  dette er ett kort eksempel, ikke en måling av lange samtaler eller kald oppstart.
- En midlertidig diagnose i den installerte appen kjørte samme fil gjennom
  `NBWhisper.transcribe`, og kontrollerte mikrofon → midlertidig WAV → NB-resultat
  → opprydding. Begge fullførte uten feil.
- Avbryt under aktiv NB-hjelpeprosess ga `CancellationError` og avsluttet prosessen.
- Diagnosekoden er fjernet. Ingen automatiserte testfiler er opprettet.

NB er standardmotor. Apple lager forhåndsvisningen, og NB erstatter den ved stopp
før normal kopiering og eventuell innliming. Lange spontane opptak og faktisk
innlimingsresultat med NB må fortsatt prøves av brukeren.

## Whisper i 20-sekunders bolker, 15. september 2026

Denne versjonen erstatter Apple-forhåndsvisning og etterbehandling av hele opptaket
med en egen Whisper-økt. Mac-diktasjon kan velges separat i innstillingene.

- Debug- og release-bygg fullførte med CWhisper statisk lenket i appen.
- En syntetisk norsk lydfil på 47,27 sekunder ble sendt gjennom produksjonskodens
  bolkdeling, native modell og tekstskjøting. Tre bolker (20, 24 og 11,27 sekunder,
  inkludert fire sekunders overlapp) tok omtrent 3,3, 3,7 og 1,3 sekunder å behandle
  på denne MacBook Air M2. Dette er enkeltmålinger, ikke en garanti for lange opptak.
- Gjentatt tekst i overlappen ble fjernet. Tidsstempelbasert skjøting ble forkastet
  fordi upresise ordtider nær pauser kunne fjerne ord; nå matches selve teksten.
- Modellen utelot én setning i siste bolk. Samme utelatelse ble gjenskapt med
  whisper-cli på identisk lyd uten VAD, så dette skyldes ikke tekstskjøtingen.
- Avbryt under native modellkjøring ga CancellationError og avsluttet behandlingen.
- Midlertidig instrumentering i den installerte appen tok opp mikrofonen i 25
  sekunder. Første bolk ble ferdig før stopp. Den stille resten ble ferdigstilt
  på ca. 0,05 sekunder. Deretter startet og ferdigstilte Mac-motoren en egen økt.
  Begge fullførte uten feil. Ingen tekst ble kopiert eller limt inn under kontrollen.
- Diagnosekode er fjernet før endelig installasjon. Ingen testfiler er opprettet.

Flere minutters spontan tale, engelsk med bolkdeling, køoverløp, tap av mikrofon og
innliming i målapp er ikke kontrollert på nytt i denne runden. Langvarig kvalitet
og ventetid må prøves med reell bruk; overlapp garanterer ikke at all tale blir korrekt.

## Rask opptaksstart og lydindikator, 15. september 2026

- Whisper forhåndslastes og gjenbrukes mellom økter. Mikrofonstart er flyttet foran
  venting på modellen; lyd samles i den eksisterende køen under eventuell lasting.
- To påfølgende mikrofonøkter startet på 0,22 og 0,13 sekunder i release-appen.
  Første økt ble avbrutt, andre ferdigstilt. Begge ga løpende lydnivåcallbacker.
  Ny klargjøring av den samme modellen tok ca. 0,0002 sekunder.
- Permanent modellhold avdekket en Metal-assert ved appavslutning. Eksplisitt
  frigjøring før avslutning rettet dette; samme kontroll avsluttet med exitkode 0.
- Opptakspanelet viser nå syv faste, symmetriske søyler i en mørk kapsel.
  Høyden styres av målt mikrofon-RMS, uten tekstforhåndsvisning eller statustekst.
  Under ferdigstilling vises bare estimert prosent, begrenset til 99 før resultatet
  er klart. Estimatet tilpasses målte behandlingstider for bolker med tale.
- Diagnosekoden er fjernet. Ingen testfiler er opprettet. Lydcallbackene og
  start/stopp er kontrollert; det endelige panelet er ikke visuelt kontrollert.

## Fremdrift fra behandlet lyd, 15. september 2026

- Fjernet tidsbasert prosent og modellen for anslått behandlingstid. Prosenten
  vekter ferdige bolker etter antall lydprøver, med Whispers native callback for
  den aktive bolken. Nevneren låses etter at lydstrømmen er avsluttet og tømt.
  Overlapp inngår i arbeidsmengden, og en ren overlappsrest sendes ikke til modellen.
- Native fremdrift lagres atomisk og nullstilles før hver kjøring. UI leser verdien
  hvert 50 ms; 100 settes bare når hele øktresultatet foreligger. Den tidligere
  regelen om å telle ett tall per oppdatering er fjernet, så UI ikke henger etter.
- Debug- og release-bygg besto. En midlertidig diagnose kjørte den eksisterende
  syntetiske filen gjennom appens native modell: 0 % ved start, 63 % etter 4,56 s,
  ferdig etter 7,31 s. Dette bekrefter grov rapportering fra motoren; kortere
  bolker kan bli ferdige uten mellomliggende prosentverdier.
- Mac-motoren rapporterer ikke slik fremdrift og viser 0 frem til fullføring.
- Diagnosekoden er fjernet. Ingen testfiler er opprettet. Endelig visuell animasjon
  og fremdrift under lange, spontane mikrofonopptak er ikke kontrollert på nytt.

## Avbryt fra panelet og Escape

- Panelet har en synlig × med en 28 × 28 punkters trefflate. Den avbryter
  klargjøring, opptak og ferdigstilling, og lukker panelet umiddelbart.
  Etter at levering er startet, lukker den bare panelet.
- Lokale og globale Escape-lyttere finnes bare mens panelet er synlig. Den
  eksisterende Ctrl + Option + Escape-snarveien er beholdt.
- En midlertidig diagnose ved normal LaunchServices-oppstart bekreftet
  Tilgjengelighet og tastetilgang. En sendt Escape endret recording til idle;
  panelets lukkehandling avbrøt neste økt til idle. Utklippstavlen var uendret.
- Direkte oppstart av programfilen fra agentmiljøet hadde annen tilgangsattribusjon;
  den endelige kontrollen brukte derfor vanlig appstart via open.
- Ingen testfiler er opprettet. Diagnosekoden er fjernet. Den faktiske museklikken
  på × og avbryt midt i en lang Whisper-beregning ble ikke prøvd på nytt.

## Teaminstallasjon og appikon, 15. september 2026

- Ny releaseprosess lager en ferdigbygd arm64-app, et selvstendig install.sh og
  SHA256SUMS. Arkivet er ca. 2,7 MB, med ikon og tredjepartslisenser, uten modeller
  eller opptak. Native kode bygges uten CPU-tilpasning til utviklermaskinen og med
  macOS 26.0 som minimum. Appens Mach-O-metadata bekrefter minimum 26.0.
- Installasjon i en separat mappe og oppdatering av samme installasjon fullførte.
  SHA-256, utpakking og signatur ble kontrollert. Eksisterende språkmodeller ble
  verifisert og gjenbrukt. En fersk Silero-nedlasting ble verifisert med samme
  modellfunksjon; NB-modellen ble kontrollert fra eksisterende fil.
- En ugyldig appfil ble avvist før erstatning. Den tidligere installasjonens
  signatur var fortsatt gyldig etterpå. Bash-syntaks for alle skriptene besto.
- Appikonet er generert med imagegen, visuelt inspisert og pakket som .icns.
- Ingen tester er opprettet. Installasjon på en annen Mac, Gatekeeper hos teamet
  og avbrudd midt i en stor modellnedlasting er ikke manuelt kontrollert.
  Developer ID og notarisering er foreløpig ikke tilgjengelig.

## Dikta 0.5.1

- Appnavn, kjørbar fil, paneltekster og releasepakke heter Dikta. Eksisterende
  bundle-ID og modellmappe er beholdt for å videreføre innstillinger og modeller.
- Installereren oppgraderte en tidligere Diktat.app i isolert mappe til Dikta.app,
  fjernet den gamle appen med matching identitet og gjenbrukte begge modellene.
  Info.plist viser Dikta; signaturkontroll besto.
- README er redusert til 30 linjer; tekniske detaljer ligger i docs/TECHNICAL.md.

## Valg av NB-Whisper Large, 16. september 2026

- Medium/Large-valg med lagring i brukerinnstillinger, bakgrunnsnedlasting,
  bytefremdrift, avbryt og nytt forsøk. Pågående økter låser modellvalget ved start.
- Large-filen (3 095 033 483 byte) ble lastet ned i appen og SHA-256-kontrollert
  før installasjon. Medium var tilgjengelig mens nedlastingen pågikk.
- Large lastet og transkriberte 20 sekunder av den eksisterende syntetiske norske
  prøvefilen (45 ordobjekter). Deretter lastet og transkriberte Medium samme lyd.
  Appen avsluttet normalt. Det opprinnelige modellvalget ble gjenopprettet.
- Den første async-URLSession-varianten ga ikke bytecallbacker. Den ble erstattet
  med eksplisitt URLSessionDownloadTask/delegate. Den endelige nedlastingsklassen
  rapporterte 14 416, 96 291, 622 538 og 885 098 byte ved en fersk VAD-nedlasting.
  Avbryt av en aktiv nedlasting returnerte NSURLErrorCancelled (-999).
- Filkontrollen går utenfor hovedtråden. Nedlastingen bruker midlertidig fil;
  bare en fil med riktig størrelse og SHA-256 gjøres tilgjengelig som modell.
- Ingen testfiler er opprettet. Diagnosekoden er fjernet før release. Feil checksum,
  nettbrudd og selve visningen i innstillingsvinduet er ikke manuelt fremprovosert.
