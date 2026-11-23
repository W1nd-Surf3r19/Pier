# Pier

Ein eigener Dock-Ersatz für macOS, gebaut mit Swift und SwiftUI. Pier blendet das Mac-Dock aus und stellt es beim Beenden wieder her. Der Dock-Prozess selbst läuft weiter, deshalb funktionieren Mission Control, Spaces und ⌘-Tab wie gewohnt.

## Funktionen

**Dock**
- Zwei Stile: schwebende Pille (Launcher · Apps · Widgets) oder durchgehende Leiste
- Position unten, links, rechts oder oben (gilt nur für die Pille, die Leiste ist immer unten), auf Wunsch auf allen Bildschirmen
- Automatisches Ausblenden
- Neun Farbthemen (System, Graphit, Mitternacht, Ozean, Lavendel, Koralle, Salbei, Abendrot, Transparent): Akzentfarbe für die aktive App, Fortschritt und Auswahl sowie eine leichte Tönung des Glases von Dock, Popups, Launcher und ⌥Tab. „Transparent“ lässt das Glas im Dock ganz weg
- Beschriftung der Leiste: automatisch (Name nur bei genug Platz), nur Icons oder immer Icon und Text
- Badges: in breiten Leisten-Tabs groß und rot rechts im Tab, sonst klein am Icon, dazu im Tooltip (die Werte kommen aus dem versteckten Mac-Dock)
- Aufmerksamkeit: Erscheint oder steigt ein Badge, blinkt die ganze Kachel
- App-Fortschritt: Downloads und Kopiervorgänge füllen den Tab und zeigen „14 %“; die Titelposition von Music, Spotify und VLC erscheint als grüner Balken (Music und VLC fragen beim ersten Mal nach der Erlaubnis, sie zu steuern)
- App-Status: startende Apps mit wandernden Streifen, Apps, die nicht reagieren, mit roten Streifen und „Reagiert nicht“; ausgeblendete Apps und minimierte Fenster abgeblendet
- Anpinnen und Lösen über das Kontextmenü, Drag & Drop (Datei auf App öffnet sie, `.app` pinnt an, Ordner wird zum Stapel)
- Finder-Stapel mit den neuesten Dateien eines Ordners
- „Intelligent anordnen“: gruppiert Apps nach Kategorie und Nutzung, mit Trennlinien und verschiebbaren Gruppen
- ⌃ halten zeigt CPU- und Speicherverbrauch der laufenden Apps
- Apps lassen sich von der Anzeige ausschließen, „Sofort beenden…“ fragt vorher nach

**Fenster**
- Fenster-Vorschau beim Überfahren, Fenster lassen sich aus der Vorschau ziehen
- Scrollen über einem Icon wechselt zwischen den Fenstern der App
- Filter auf den aktuellen Space
- ⌥Tab-Umschalter: ⌥ halten, mit Tab (⇧Tab rückwärts) wählen, ⌥ loslassen wechselt, ⌥Esc bricht ab
- Scrollen auf der Titelleiste (muss eingeschaltet werden): hoch = maximieren, runter = zentrieren, links/rechts = Bildschirmhälfte
- Fenster, die unter das Dock reichen würden, werden bis zu dessen Oberkante gekürzt

**Launcher und Widgets**
- Launchpad-Ersatz mit Sofortsuche, öffnet über die Dock-Kachel oder ⌥ Leertaste
- ⌃⌥1–9 startet die n-te App
- Musik-Widget für Music und Spotify mit Steuerung über die Medientasten

## Voraussetzungen

- macOS 15 oder neuer
- Swift 6 (Xcode oder Command Line Tools)
- Berechtigungen unter *Systemeinstellungen › Datenschutz & Sicherheit*: **Bedienungshilfen** (für Fenster, Badges und Tastenkürzel) und **Bildschirmaufnahme** (für die Fenster-Vorschau)

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
