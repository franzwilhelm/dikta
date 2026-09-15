# Norske lokale talemodeller for lange samtaler

Undersøkt 15. september 2026. Dokumentresearch; ingen modeller lastet ned eller kjørt.

## Vurdering

**NB-Whisper Large er første kandidat for bedre norsk i Diktat.** Dette er en anbefaling ut fra norske målinger, ikke en verifisert forbedring over Apples DictationTranscriber eller på brukerens samtaler. NB-Whisper Medium er en relevant kandidat dersom Large blir for treg på M2 med 16 GB minne.

## Verifisert i primærkilder

Nasjonalbibliotekets artikkel rapporterer følgende ordfeilrate, WER (lavere er bedre):

| Modell | FLEURS bokmål | NST bokmål |
| --- | ---: | ---: |
| OpenAI Whisper Large-v3 | 10,4 % | 6,8 % |
| NB-Whisper Large | 6,6 % | 2,2 % |
| NB-Whisper Medium | 7,2 % | 2,3 % |

Forskerne evaluerer hovedsakelig manusbasert/opplest tale. FLEURS er utenfor treningsdomenet; NST-testen har andre talere enn treningsdataene. Tegnsetting og store bokstaver fjernes ved beregningen. Målingene dokumenterer derfor ikke tegnsettingskvalitet. Lang transkripsjon og hallusinasjoner ble bare vurdert kvalitativt, fordi egnede norske datasett manglet. [Forskningsartikkel, tabell 4–6 og avsnitt 5–7](https://arxiv.org/html/2402.01917v1)

NB-Whisper Large er videreutviklet fra Whisper Large-v3, med 1,55 milliarder parametere. Modellkortet oppgir bokmål, nynorsk og engelsk. Standardmodellen lager grammatisk skrevet tekst og er ikke nødvendigvis ordrett; den kan utelate tale eller produsere tekst som ikke ble sagt. Modellkortet beskriver lokal kjøring og offisielle whisper.cpp-filer. Det anbefaler 28-sekunders biter og eventuelt beam size 5 i sitt Transformers-eksempel. Dette er innstillinger for den konkrete implementasjonen, ikke universelle optimalverdier. [Nasjonalbibliotekets modellkort](https://huggingface.co/NbAiLab/nb-whisper-large)

Offisielle nedlastinger for whisper.cpp er **1,08 GB** for `ggml-model-q5_0.bin` og **3,1 GB** for `ggml-model.bin`. Dette er filstørrelser, ikke målt samlet minnebruk. [Offisiell filliste](https://huggingface.co/NbAiLab/nb-whisper-large/tree/main)

Whisper Large-v3 Turbo har redusert dekoderen fra 32 til 4 lag for høyere fart med noe kvalitetstap. Whisper ser 30 sekunder lyd av gangen; lange opptak krever sekvensielle vinduer eller overlappende biter som settes sammen. Turbo-kortet beskriver begge strategiene, og sier at sekvensiell behandling er aktuell når kvalitet prioriteres. Ingen norsk NB-Whisper-vs-Turbo-måling ble funnet i disse kildene. [Offisielt Turbo-modellkort](https://huggingface.co/openai/whisper-large-v3-turbo)

Modellkortets «Verbatim»-avsnitt beskriver en mer bokstavelig variant, men Large-lenken peker på `NbAiLab/nb-whisper-large-semantic`, som svarte 401 ved oppslag. Tilgjengelighet og egenskaper til en separat ordrett Large-variant er derfor ikke bekreftet. [Modellkortets variantavsnitt](https://huggingface.co/NbAiLab/nb-whisper-large#verbatim-model)

## Konsekvenser for Diktat — faglig vurdering

- Begynn med NB-Whisper Large som kvalitetskandidat og Medium som alternativ for fart. Ikke anta at generisk Turbo gir bedre norsk bare fordi det er nyere eller raskere.
- En modellnedlasting alene løser ikke lange opptak. Integrasjonen trenger lydsegmentering, håndtering av pauser og kontroll på sammenføyning slik at ord ikke forsvinner eller dobles ved grensene.
- En større Whisper-modell får ikke hele samtalen som sammenhengende lydkontekst; «lang samtale» støttes gjennom behandling av flere vinduer.
- En manuell sammenligning av samme representative opptak bør avgjøre modellvalg: norske dialekter, engelske fagord/navn, selvkorrigering, stillhet og eventuelt flere talere. Vurder feil som endrer mening, utelatelser og tegnsetting, i tillegg til ventetid.
- Mål faktisk fart og minnebruk på brukerens M2. Filstørrelsen gjør lokal utprøving plausibel, men dokumentasjonen her gir ikke et troverdig fartsløfte for den maskinen.
- Skille mellom hvem som snakker er en egen funksjon; NB-kortet foreslår WhisperX og pyannote for dette. Ikke lov talermerking som en automatisk effekt av modellbyttet. [Modellkortets diariseringsavsnitt](https://huggingface.co/NbAiLab/nb-whisper-large#whisperx-and-speaker-diarization)

## Avgrensning

Dette er en kort vurdering av NB-Whisper mot OpenAI Whisper. Den dokumenterer ikke at Apples nåværende modell er dårligere, eller at NB-Whisper er best blant alle tilgjengelige modeller i 2026. Nasjonalbibliotekets tall er fra 2024 og dekker ikke brukerens lange spontane samtaler. Kjøring på Mac, runtime-valg og andre modellfamilier undersøkes separat.
