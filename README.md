# Dikta

<img src="Resources/AppIcon.png" width="96" alt="Dikta">

Lokal diktasjon fra menyfeltet. Snakk, stopp, og få teksten limt inn der du jobber.

## Installer

Krever **Apple Silicon og macOS 26+**. Ingen Xcode eller Homebrew.

```sh
curl -fsSL https://github.com/franzwilhelm/dikta/releases/latest/download/install.sh | bash
```

Appen åpnes automatisk. Whisper-modellene lastes ned separat første gang, ca. **1,53 GB**.
Gi mikrofontilgang og aktiver **Tilgjengelighet** for automatisk innliming og Escape.
Appen er ikke notarisert ennå; macOS kan kreve «Åpne likevel» under Personvern og sikkerhet.

For å oppdatere: avslutt Dikta og kjør samme kommando igjen.

## Bruk

- **Start/stopp:** Ctrl + Option + mellomrom.
- **Avbryt:** Escape eller × på panelet.
- **Innstillinger:** Velg NB-Whisper (Medium/Large) eller Mac-diktasjon, norsk eller engelsk, og automatisk innliming eller bare kopiering.
- **Lydfil:** «Transkriber lydfil …» i menyen tar et opptak fra f.eks. mobilen (m4a, mp3, wav) og kopierer teksten.
- **Kopier igjen:** «Kopier siste tekst» i menyen.
- **Rydd opp teksten:** Valgfritt, av som standard. Fjerner fyllord, stamming og gjentakelser med Apples språkmodell på Mac-en. Krever Apple Intelligence.
- **Tidligere økter:** «Tidligere økter …» i menyen viser alle dikteringer og transkriberte lydfiler, med søk, kopiering og ny transkripsjon av lydopptaket.

Tale behandles lokalt. Hver økt lagres med tekst og lyd på din Mac, i `~/Library/Application Support/Diktat/History`, også hvis appen krasjer underveis. Transkripsjonen kan inneholde feil eller utelatelser.

[Tekniske detaljer](docs/TECHNICAL.md) · [Bygg og utgivelser](RELEASING.md)
