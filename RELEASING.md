# Utgivelser

Repo: `franzwilhelm/dikta`. Appnavnet er Dikta. Den eksisterende appidentiteten beholdes som
`no.franzvonderlippe.Diktat`, slik at lokale innstillinger beholdes.

## Lag app og installasjonsskript

På Apple Silicon med Swift Command Line Tools, CMake og Git:

1. Oppdater versjon og byggenummer i `Resources/Info.plist`.
2. Kjør `./scripts/release.sh`.
3. Kontroller `dist/release/v<VERSJON>/`.

Utgivelsen inneholder bare:

- `Dikta-<VERSJON>-macos-arm64.zip`: app med ikon, native whisper.cpp-kjøretid og lisenser.
- `install.sh`: selvstendig installasjonsskript med fast URL og SHA-256 for akkurat denne apppakken.
- `SHA256SUMS`: kontrollsummer for de to filene.

**Ingen modeller eller opptak ligger i arkivet.** Utgivelsesbygging laster heller
ikke ned språkmodellene. `scripts/download-models.sh` og det genererte skriptet
bruker de samme pinnede modelladressene og kontrollsummene.

`DIKTAT_REPOSITORY` og `DIKTAT_RELEASE_BASE_URL` kan overstyre nedlastingsstedet
ved bygging. Bytt aldri app-arkivet alene i en utgivelse: generer og last opp nytt
installasjonsskript med tilhørende kontrollsum, eller opprett en ny versjon.

## Publiser på GitHub

Kommandoen nedenfor forutsetter et offentlig repo og en ferdig gjennomgått commit:

```sh
gh release create v0.6.0 dist/release/v0.6.0/* \
  --repo franzwilhelm/dikta --target main \
  --title 'Dikta 0.6.0' --notes-file RELEASE_NOTES.md
```

Den permanente installasjonskommandoen peker på siste publiserte release:

```sh
curl -fsSL https://github.com/franzwilhelm/dikta/releases/latest/download/install.sh | bash
```

Det genererte skriptet peker videre på en versjonsfast appfil. Et privat repo
krever en autentisert nedlastingsflyt; curl-kommandoen over fungerer ikke anonymt.

## Lokal kontroll uten publisering

Avslutt Dikta først. Installer den genererte pakken i en midlertidig mappe:

```sh
DIKTAT_INSTALL_DIR="$(mktemp -d)/Applications" \
DIKTAT_ARCHIVE_PATH="$PWD/dist/release/v0.6.0/Dikta-0.6.0-macos-arm64.zip" \
DIKTAT_NO_OPEN=1 bash dist/release/v0.6.0/install.sh
```

Dette bruker samme kontrollsum, utpakking, signaturkontroll og modellnedlasting
som vanlig installasjon. `DIKTAT_ARCHIVE_PATH` brukes bare for lokal/offline
appfil; modeller hentes fortsatt hvis de mangler. `DIKTAT_MODEL_DIR` finnes for
isolert installasjonskontroll; appen selv bruker alltid standardmappen i
`~/Library/Application Support/Diktat/Models`.

## Signering

`DIKTAT_SIGNING_IDENTITY` kan angi et signeringssertifikat. Standard er ad hoc.
Developer ID-distribusjon krever i tillegg hardened runtime, notarisering og
stapling før arkivet og kontrollsummene lages; dette er ikke konfigurert ennå.
Ingen skript endrer Gatekeeper-innstillinger eller macOS-personverntillatelser.
