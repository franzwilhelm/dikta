Velg **Medium eller Large** under Whisper-modell i innstillingene.

- Large lastes ned i bakgrunnen når den velges, med nedlastingsstatus i innstillingene.
- Nedlastingen kan avbrytes eller prøves igjen ved feil. Modellfilen kontrolleres med SHA-256.
- Medium brukes inntil Large er klar. Pågående opptak bytter aldri modell underveis.
- Nedlastede modeller og modellvalget beholdes mellom appstarter.

Large er en separat nedlasting på ca. 3,10 GB og krever mer minne og behandlingstid.
Installasjonskommandoen laster fortsatt bare ned Medium som standard.
