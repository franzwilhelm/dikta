# Lokal talegjenkjenning for lange norske samtaler

Undersøkt 15. september 2026. Målmaskinen er en MacBook Air M2 med 16 GB minne, kontrollert lokalt. Appen er Swift på macOS 26. Ingen modeller er lastet ned eller kjørt i denne undersøkelsen.

## Anbefaling

Prøv **NB-Whisper large via whisper.cpp** først, med norsk som eksplisitt språk. Begrunnelsen er norsktilpasningen og publiserte norske resultater; se [modellundersøkelsen](norwegian-models.md). Dette er en anbefaling om hvilken kandidat som bør prøves, ikke en konklusjon om at den allerede er bedre enn Apples diktasjon på brukerens tale.

Bruk i første omgang den ukvantiserte GGML-modellen som kvalitetsreferanse. Nasjonalbiblioteket tilbyr `ggml-model.bin` på 3,1 GB og en Q5-versjon på 1,08 GB. Last bare ned ønsket modellfil, ikke hele modellarkivet med flere eksportformater. Q5 er et alternativ ved minne-/hastighetsproblemer; lik transkripsjonskvalitet må ikke tas for gitt. [Offisiell filliste](https://huggingface.co/NbAiLab/nb-whisper-large/tree/main).

## Kjøremotor på Mac

`whisper.cpp` støtter Apple Silicon med Metal og valgfri Core ML-akselerasjon, et C-grensesnitt og Swift-integrasjon via XCFramework. Prosjektets generelle estimat for large er rundt 3,9 GB arbeidsminne. Min vurdering er at 16 GB gjør lokal kjøring realistisk, men faktisk minnebruk og hastighet på denne Mac-en må måles med aktuell modell, lydlengde og andre åpne apper. Dokumentasjonen støtter også taleaktivitetsdeteksjon (VAD), som skiller tale fra stillhet og tilbyr overlapp/padding ved segmentgrenser. [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

WhisperKit, nå i Argmax OSS Swift, er et alternativ med direkte Swift-API, Core ML-modeller og inkrementell innlesing av lange filer. NB-Whisper trenger en kompatibel Core ML-konvertering; tilpassede Whisper-modeller kan konverteres med prosjektets verktøy. GGML-filene kan ikke brukes direkte. Dokumentasjonen oppgir Xcode 16+; her er bare Command Line Tools installert. Derfor velger jeg whisper.cpp som enkleste vei til å prøve nettopp NB-modellen. [Argmax OSS Swift](https://github.com/argmaxinc/argmax-oss-swift).

## Andre aktuelle modeller

| Kandidat | Vurdering for Diktat |
|---|---|
| NB-Whisper large | Første kandidat for norsk kvalitet. |
| NB-Whisper medium | Kandidat hvis large gir for mye venting; norske målinger ligger nær large på de undersøkte datasettene. |
| Whisper large-v3 / turbo | Relevant sammenligningsgrunnlag og separat kandidat for engelsk; ikke dokumentert som best på norsk. |
| Parakeet TDT 0.6B v3 | Utelates som norsk hovedmodell: norsk er ikke i NVIDIAs liste over 25 støttede språk. |
| Qwen3-ASR 1.7B | Utelates som norsk hovedmodell: norsk er ikke i den offisielle listen over 30 språk. |

Kilder: [NB-Whisper-undersøkelsen](norwegian-models.md), [NVIDIAs modellkort](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [Qwens modellkort](https://huggingface.co/Qwen/Qwen3-ASR-1.7B). Språkstøtte på svensk og dansk er ikke dokumentasjon på norsk kvalitet.

## Lange samtaler krever mer enn en større modell

Whispers referanseimplementasjon arbeider i lydvinduer og kan bruke tidligere tekst som kontekst; dette er ikke en modell som vurderer en hel times samtale samtidig. Implementasjonen har også mekanismer mot repetisjoner og feil ved stillhet. Modellkortet beskriver risiko for tekst som ikke ble sagt. [Transkripsjonskode](https://github.com/openai/whisper/blob/main/whisper/transcribe.py), [modellkort](https://github.com/openai/whisper/blob/main/model-card.md).

Foreslått endring i Diktat, ikke implementert:

1. Behold lyd lenge nok til at den nye modellen kan transkribere den. Den eksisterende tekstbufferen alene kan ikke brukes til ny talegjenkjenning.
2. Behandle lyd løpende i avgrensede biter med pauser og litt overlapp; samle tekst uten duplikater.
3. Ved stopp ferdigstilles køen før kopiering/innliming. Dagens faste ferdigstillingsgrense på 30 sekunder må revurderes for en større lokal modell.
4. Hvis opptaket har flere deltakere, vurder egen talermerking. En vanlig transkripsjonsmodell identifiserer ikke automatisk hvem som snakker.
5. Vurder transkripsjonen før eventuell språkvask. Omskriving kan gjøre feil mer velformulerte uten å rette dem.

## Hva avgjør valget

En manuell sammenligning på samme representative norske opptak: utelatte eller oppdiktede ord, navn/faguttrykk, dialekt, tegnsetting, gjentakelser og ventetid ved stopp. Bruk også et lengre opptak for å se feil ved segmentgrenser. Ingen nye automatiserte tester er foreslått.

Ingen undersøkt kilde gir en direkte sammenligning mellom dagens `DictationTranscriber` og kandidatene på brukerens lange samtaler. Publiserte norske resultater er grunn til å prioritere NB-Whisper, ikke en garanti for resultatet i Diktat.
