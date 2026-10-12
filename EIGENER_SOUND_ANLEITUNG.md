# LidAngleSensor – mit eigenem Mikrofon-Sound

Neu in dieser Version: Modus **Custom**. Du nimmst mit dem Mikrofon einen Sound auf,
und der wird beim Bewegen des Deckels abgespielt (wie das Knarzen: langsam = laut,
schnell = leise, Tonhöhe folgt der Geschwindigkeit).

## Bauen (einmalig)
1. Ordner entpacken, `LidAngleSensor.xcodeproj` in Xcode (16 oder neuer) öffnen.
2. Oben „My Mac" als Ziel wählen und **⌘R** drücken.
   Signiert wird lokal („Sign to Run Locally"), du brauchst keinen Apple-Developer-Account.
   Falls Xcode trotzdem nach einem Team fragt: Target → *Signing & Capabilities* → dein
   persönliches Team auswählen.
3. Die fertige App findest du über *Product → Show Build Folder in Finder* und kannst sie
   in den Programme-Ordner ziehen.

## Benutzen
1. Im Seitenpanel (Regler-Symbol) unter *Audio Mode* **Custom** wählen.
2. **Record with Microphone** klicken (oder ⌘R), beim ersten Mal den Mikrofonzugriff erlauben.
3. Sound machen, dann **Stop Recording** (stoppt automatisch nach 10 s).
4. **Play** drücken und den Deckel bewegen.

Stille am Anfang/Ende wird automatisch abgeschnitten, die Lautstärke normalisiert und
die Enden kurz ausgeblendet, damit die Schleife nicht klickt. Die Regler für Lautstärke,
Tonhöhe und Ramping funktionieren wie beim Creak-Modus.
Aufnehmen geht auch über das Menüleisten-Symbol („Record Custom Sound…").

Die Aufnahme liegt unter `~/Library/Application Support/LidAngleSensor/CustomSound.wav`
und bleibt nach dem Neustart erhalten. „Delete Sound" löscht sie.

## Geänderte Dateien
- `AudioEngines/SoundRecorder.swift` (neu) – Mikrofonaufnahme
- `AudioEngines/CreakAudioEngine.swift` – kann beliebige Sounds laden
- `AudioEngines/AudioMode.swift` – Modus „Custom"
- `AudioController.swift`, `ContentView.swift`, `MenuBarView.swift` – Logik & Oberfläche
- `LidAngleSensor.entitlements` (neu) + Projekteinstellungen – Mikrofon-Berechtigung
