# Sicherheit / Security

Bitte melde Sicherheitslücken **nicht** als öffentliches Issue, sondern über
*Security → Report a vulnerability* in diesem Repository (private Meldung) oder per E-Mail an
kontakt@malte-rill.de. Ich antworte in der Regel innerhalb einer Woche.

Please report security issues privately via *Security → Report a vulnerability* in this
repository or by email to kontakt@malte-rill.de – not as a public issue.

## Was Pier darf / What Pier can access

- **Bedienungshilfen / Accessibility:** Fenster lesen und bewegen, Badges aus dem Mac-Dock lesen, Tastenkürzel
- **Bildschirmaufnahme / Screen Recording:** nur für die Fenster-Vorschau
- **Apple Events:** Titelposition und Cover aus Music, Spotify und VLC
- **Bluetooth:** nur wenn die Bluetooth-Liste eingeschaltet ist
- Ändert die Mac-Dock-Einstellungen `autohide` und `autohide-delay` (beim Beenden wiederhergestellt)

Pier sendet keine Daten ins Internet. Einzige Netzabfrage: das Albumcover von Spotify (Bild-URL aus Spotify selbst).
Pier sends no data anywhere. The only network request loads the Spotify album cover from the URL Spotify provides.
