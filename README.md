# Pier

Ein eigener Dock-Ersatz für macOS, gebaut mit Swift und SwiftUI. Pier blendet das Mac-Dock aus und stellt es beim Beenden wieder her. Der Dock-Prozess selbst läuft weiter, deshalb funktionieren Mission Control, Spaces und ⌘-Tab wie gewohnt.

## Funktionen

**Dock**
- Zwei Stile: schwebende Pille (Launcher · Apps · Widgets) oder durchgehende Leiste
- Position unten, links, rechts oder oben – für Pille und Leiste; die Pille sitzt in der Mitte, am Anfang oder am Ende ihrer Kante oder schwebt frei (am Griff ziehen, die Stelle bleibt gespeichert)
- Bildschirm wählbar: Hauptbildschirm, ein bestimmter Bildschirm oder alle
- Automatisches Ausblenden
- Farbthemen (System, Graphit, Mitternacht, Ozean, Lavendel, Koralle, Salbei, Abendrot, Transparent, eigene Farbe und „Now Playing“, das sich nach dem Cover des laufenden Titels in Music oder Spotify färbt): Akzentfarbe für die aktive App, Fortschritt und Auswahl sowie eine leichte Tönung des Glases von Dock, Popups, Launcher und ⌥Tab. „Transparent“ lässt das Glas im Dock ganz weg
- Beschriftung der Leiste: automatisch (Name nur bei genug Platz), nur Icons oder immer Icon und Text
- Leiste oben oder unten mit 1 bis 5 Zeilen: am Innenrand ziehen oder in den Einstellungen wählen
- Leiste links oder rechts als Spalte: mit Titeln 210 pt breit, bei „Nur Icons“ schmal; passen nicht alle Tabs hinein, werden sie flacher
- Badges: in breiten Leisten-Tabs groß und rot rechts im Tab, sonst klein am Icon, dazu im Tooltip (die Werte kommen aus dem versteckten Mac-Dock)
- Aufmerksamkeit: Erscheint oder steigt ein Badge, blinkt die ganze Kachel
- App-Fortschritt: Downloads und Kopiervorgänge füllen den Tab und zeigen „14 %“; die Titelposition von Music, Spotify und VLC erscheint als grüner Balken (Music und VLC fragen beim ersten Mal nach der Erlaubnis, sie zu steuern)
- App-Status: startende Apps mit wandernden Streifen, Apps, die nicht reagieren, mit roten Streifen und „Reagiert nicht“; ausgeblendete Apps und minimierte Fenster abgeblendet
- Anpinnen und Lösen über das Kontextmenü, Drag & Drop (Datei auf App öffnet sie, `.app` pinnt an, Ordner wird zum Stapel, andere Dateien auf freier Fläche werden angepinnt)
- Reihenfolge der laufenden, nicht angepinnten Apps: nach Start, alphabetisch oder in ihre Gruppe einsortiert – z. B. landet ein geöffnetes Xcode hinter den angepinnten Entwickler-Apps (angepinnte bleiben in deiner Reihenfolge)
- Finder-Stapel mit den neuesten Dateien eines Ordners
- „Intelligent anordnen“: gruppiert Apps nach Kategorie und Nutzung, mit Trennlinien und verschiebbaren Gruppen
- ⌃ halten zeigt CPU- und Speicherverbrauch der laufenden Apps
- Apps lassen sich von der Anzeige ausschließen, „Sofort beenden…“ fragt vorher nach

**Fenster**
- Fenster-Vorschau beim Überfahren, Fenster lassen sich aus der Vorschau ziehen
- Fenster gruppieren (Leiste): nie, immer oder automatisch, sobald die Tabs zu schmal werden; ein gemeinsamer Tab zeigt die Zahl der Fenster
- Scrollen über einem Icon wechselt zwischen den Fenstern der App
- Filter auf den aktuellen Space
- ⌥Tab-Umschalter: ⌥ halten, mit Tab (⇧Tab rückwärts) wählen, ⌥ loslassen wechselt, ⌥Esc bricht ab
- Scrollen auf der Titelleiste (muss eingeschaltet werden): hoch = maximieren, runter = zentrieren, links/rechts = Bildschirmhälfte
- Fenster, die unter das Dock reichen würden, werden bis an dessen Rand gekürzt bzw. verschoben (Leiste an jeder Kante, Pille unten)

**Launcher und Widgets**
- Launchpad-Ersatz mit Sofortsuche über Apps, Bereiche der Systemeinstellungen und Ordner (Benutzerordner plus eigene), öffnet über die Dock-Kachel oder ⌥ Leertaste
- ⌃⌥1–9 startet die n-te App
- Musik-Widget für Music und Spotify mit Steuerung über die Medientasten; in der Leiste wird stattdessen der Tab des Players breiter und zeigt Titel, Interpret, Abspielen/Pause und Weiter
- Uhr: darüberfahren zeigt Kalender (Woche ab Montag) und Zifferblatt
- Akku: darüberfahren zeigt Restlaufzeit, maximale Kapazität, Zustand und Ladezyklen
- Ton: Ausgang und Eingang per Klick wechseln
- Geräte: externe Laufwerke einzeln oder alle auswerfen, auf Wunsch gekoppelte Bluetooth-Geräte verbinden oder trennen

## Voraussetzungen

- macOS 15 oder neuer
- Swift 6 (Xcode oder Command Line Tools)
- Berechtigungen unter *Systemeinstellungen › Datenschutz & Sicherheit*: **Bedienungshilfen** (für Fenster, Badges und Tastenkürzel) und **Bildschirmaufnahme** (für die Fenster-Vorschau); **Bluetooth** nur, wenn die Bluetooth-Liste eingeschaltet ist (macOS fragt beim ersten Öffnen)

## Bauen und installieren

```sh
./build.sh            # baut build/Pier.app
./build.sh --install  # baut, beendet ein laufendes Pier und installiert nach ~/Applications
```

`build.sh` signiert die App mit einer festen Identität, damit die Berechtigungen nach einem Rebuild erhalten bleiben. Eine eigene Identität setzt du so (der Hash steht in der Ausgabe von `security find-identity -p codesigning`):

```sh
PIER_SIGN_IDENTITY=<SHA-1-Hash> ./build.sh --install
```

## Tests

```sh
swift test
```

## Konfiguration

Angepinnte Apps, Ordner und Einstellungen liegen in `~/Library/Application Support/Pier/config.json`. Ändern lässt sich alles über das Einstellungsfenster.

## Bekannte Grenzen

- Fenster in einen anderen Space zu verschieben oder die Nummer eines Space anzuzeigen geht nur über private APIs und ist deshalb nicht eingebaut.
- Jedes Dock zeigt alle Fenster an, nicht nur die auf seinem Bildschirm.
- Mit mehreren Bildschirmen ist Pier bisher nicht getestet.
