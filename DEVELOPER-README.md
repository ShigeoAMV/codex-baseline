# Codex Baseline aktuell halten

> **Start hier, wenn seit der letzten Wartung Wochen oder Monate vergangen
> sind.** Du musst den damaligen Stand nicht mehr kennen. Folge Abschnitt 1 und
> kopiere danach den Prompt aus Abschnitt 2 vollstaendig in Codex.

## 1. Repository vorbereiten

Im Terminal:

```bash
cd /home/layer9/projects/codex-baseline
git switch master
git pull --ff-only
git status --short
scripts/research-check.sh --json
```

`git status --short` sollte leer sein. Falls nicht, nichts loeschen oder
zuruecksetzen: Zeige Codex die Ausgabe und lasse zuerst klaeren, welche lokalen
Aenderungen erhalten werden muessen.

`research-check.sh` recherchiert nicht im Internet. Es zeigt nur, ob der
gespeicherte Forschungsstand und sein Review-Datum noch gueltig sind. Auch
`codex-baseline doctor --json` warnt nach Ablauf des Review-Datums.

## 2. Diesen Prompt vollstaendig in Codex kopieren

```text
Fuehre einen vollstaendigen Codex-Baseline-Wartungs- und Freshness-Refresh vom
letzten dokumentierten Forschungsstand bis zum heutigen Datum durch. Arbeite
selbststaendig bis zu einem vollstaendig getesteten Draft-PR. Merge, Tag und
GitHub Release bleiben bis zu meiner ausdruecklichen Freigabe verboten.

VERBINDLICHER START

1. Lies zuerst AGENTS.md, PLAN.md, docs/requirements/TRACEABILITY.md,
   DEVELOPER-README.md, docs/OPERATIONS.md, docs/RELEASE.md und alle Dateien
   unter docs/research/.
2. Pruefe Git-Branch, Arbeitsbaum, aktuelle Version, letztes research_checked,
   research_review_by, gespeicherte Codex-Versionen, Payload-Manifest und offene
   oder partielle Traceability-Gates. Bewahre alle fremden/lokalen Aenderungen.
3. Lege einen Wartungsplan mit messbaren Abschlusskriterien an. Nutze bei
   unabhaengiger Breite gezielt frische Reviewer/Subagenten, mit explizitem
   Scope, Ownership, Deadline und Receipt. Schreibende Parallelitaet darf nur in
   getrennten Worktrees stattfinden.

AKTUELLE INTERNETRECHERCHE IST PFLICHT

4. Recherchiere ab dem letzten dokumentierten Pruefdatum bis heute. Nutze fuer
   OpenAI/Codex zuerst aktuelle offizielle Dokumentation, Changelog,
   Feature-Maturity-/Security-/Plattformseiten und den offiziellen Quellcode
   beziehungsweise die offiziellen Releases. Pruefe mindestens:
   - Codex CLI, Desktop-App, IDE, Cloud, Windows, WSL und Linux;
   - AGENTS.md, Skills, Plugins, Hooks, Subagenten, Plan, Goal, Review,
     Worktrees, Sandbox, Permissions, Konfiguration, Automationen und Evals;
   - aktuelle Modelle und modellabhaengige Verhaltens- oder Kostenunterschiede;
   - neue Deprecations, Sicherheitsmeldungen, bekannte Fehler und Migrationen.
5. Pruefe alle bereits bewerteten Kandidaten auf neue Releases, Issues,
   Lizenzen, Plattformunterstuetzung und belastbare neue Evidenz. Dazu gehoeren
   mindestens RTK, CtxWire, Caveman, Ponytail, Headroom und JetBrains Context.
6. Suche zusaetzlich aktiv nach neuen ernstzunehmenden Alternativen fuer
   Orchestrierung, Kontext-/Token-Optimierung, Code-Discovery, Skills, Hooks,
   Evaluationswerkzeuge, Windows-Unterstuetzung und sichere Langlaeufer.
7. Suche nach relevanten unabhaengigen Benchmarks, Forschungspapieren und
   konkreten Community-/GitHub-Fehlerberichten. Herstellerclaims, Community-
   Berichte, unabhaengige Messungen und eigene Schlussfolgerungen muessen klar
   getrennt bleiben. Notiere URL, Datum, Version, Plattform, Evidenzstaerke und
   Unsicherheit. Behaupte nicht, buchstaeblich das gesamte Internet abgedeckt zu
   haben; dokumentiere stattdessen Suchraum und erkennbare Luecken.

ENTSCHEIDUNG UND IMPLEMENTIERUNG

8. Vergleiche alle neuen Fakten mit der vorhandenen Architektur und klassifiziere
   jeden materiellen Fund als:
   - zwingend aktualisieren;
   - sinnvoll experimentell evaluieren;
   - weiter beobachten;
   - weiterhin begruendet ablehnen;
   - keine relevante Aenderung.
9. Bleibe native-first, global klein und progressiv offengelegt. Fuege kein
   Framework, Plugin, Hook, Proxy, MCP, Shim, Daemon, Runtime-Dependency oder
   Token-Werkzeug nur wegen Popularitaet oder Herstellerprozenten hinzu. Eine
   Adoption braucht einen einzigartigen Nutzen, aktuelle Plattformkompatibilitaet,
   klares Trust-/Rollback-Modell und moeglichst gepaarte End-to-End-Evidenz auf
   dem dann aktuellen Codex/GPT-Stack.
10. Implementiere alle klar begruendeten kompatiblen, Sicherheits-, Forschungs-
    und Dokumentationsupdates. Pausiere und frage mich vor einer materiellen
    Architekturentscheidung, insbesondere bei neuer Config-/Hook-Ownership,
    externem Framework, Provider-/Auth-Grenze, Schema-Bruch, destruktiver
    Migration, Publisher-Schluessel oder Major-Version.
11. Aktualisiere die betroffenen Forschungsartefakte, Entscheidungen,
    Plattform-/Architektur-/Security-Dokumentation, Traceability, PLAN und den
    Research-Manifest mit aktuellem checked- und review_by-Datum. Aktualisiere
    VERSION und CHANGELOG nach SemVer nur, wenn der freigegebene Source-/Payload-
    Stand eine neue Version rechtfertigt.
12. Wenn sich der installierbare Payload aendert, erzeuge die kanonischen
    Byte-/SHA-256-/Aggregate-Werte mit scripts/release-payload.sh neu und binde
    baseline/manifest.json exakt daran. Aendere Hashes niemals per Schaetzung.

VERIFIKATION UND GITHUB

13. Nutze waehrend der Entwicklung schnelle zielgerichtete Checks. Vor dem
    finalen PR muessen mindestens Doku-Links, Research-Check, Payloadvergleich,
    Diff-Check und alle durch die Aenderung betroffenen Tests laufen. Fuer einen
    Release-Kandidaten muessen ./tests/run.sh und, wenn erreichbar,
    ./tests/run-powershell.sh vollstaendig laufen. Die Unix-Release-Suite kann
    wegen echter Crash-/Sandbox-/Canary-Negativtests mehr als eine Stunde
    dauern; halte mich waehrenddessen ueber echten Fortschritt auf dem Laufenden.
14. Lies oder kopiere niemals normale Codex-Auth-/Sessiondateien. Live-Paired-,
    Routing- und Canary-Laeufe duerfen nur mit einem dedizierten kurzlebigen Key
    und gepinntem Codex-Binary erfolgen. Falls der Key fehlt, markiere diese
    Evidenz ehrlich als pending und fahre mit allen credential-freien Checks fort.
15. Fuehre nach den Aenderungen einen frischen Security-, Architektur-/
    Maintainability- und Originalmission-Conformance-Review gegen den finalen
    Diff durch. Kritische, hohe oder mittlere begruendete Findings muessen
    geschlossen oder klar als Release-Blocker ausgewiesen werden.
16. Erstelle einen Branch agent/codex-baseline-refresh-<datum>, committe nur den
    beabsichtigten Scope, pushe ihn und oeffne einen Draft-PR gegen master. Der
    PR muss Aenderungen, Gruende, Nutzerwirkung, Quellen-/Evidenzgrenzen,
    Testresultate und offene Gates enthalten.
17. Schliesse mit einer kurzen Uebergabe ab: Was ist neu? Was wurde bewusst nicht
    uebernommen? Welche Tests liefen wirklich? Was ist noch unbewiesen? Welcher
    PR wartet auf meine Freigabe? Merge, Tag, Release und Installation bleiben
    bis zu meinem naechsten ausdruecklichen Auftrag verboten.
```

## 3. Was Codex am Ende liefern soll

Ein erfolgreicher Refresh endet mit:

- einem datierten Vergleich vom letzten Forschungsstand bis heute;
- aktualisierten offiziellen Codex-/Plattform-/Security-Fakten;
- neu bewerteten bestehenden und neu entdeckten Kandidaten;
- nachvollziehbaren Adopt-/Reject-/Experiment-/Observe-Entscheidungen;
- einem kleinen, begruendeten Diff statt blindem Framework-Stacking;
- konsistenten Versionen, Research-Daten und Payload-Hashes;
- gruenen zielgerichteten Checks und, fuer Releases, beiden Vollsuiten;
- frischen Reviews und ehrlichen verbleibenden Evidenzluecken;
- einem gepushten Draft-PR, aber noch keinem automatischen Merge oder Release.

## 4. Erst nach deiner Kontrolle veroeffentlichen

Wenn du den Draft-PR und die Zusammenfassung akzeptierst, schreibe in derselben
Codex-Konversation:

```text
Pruefe den Draft-PR nochmals gegen master, bestaetige den finalen Test- und
Trust-Status und veroeffentliche die freigegebene Version auf GitHub. Merge nur
den geprueften PR. Erstelle danach den passenden SemVer-Tag und GitHub Release.
Behalte die Bezeichnung unsigned public source preview beziehungsweise
Prerelease bei, solange keine owner-kontrollierte Signieridentitaet und kein
unabhaengig verteilter Trust Root vorhanden sind. Verifiziere abschliessend, dass
master, Tag und Release auf exakt den freigegebenen Inhalt zeigen.
```

## 5. Empfohlener Rhythmus

- **Monatlich:** kurzer read-only Release-, Changelog-, Issue- und Security-Scan.
- **Alle drei Monate:** der vollstaendige Prompt aus Abschnitt 2.
- **Sofort ausserplanmaessig:** grosses Codex-/Modellrelease, relevante
  Deprecation, Security-Advisory, Windows-/WSL-Aenderung oder ein Kandidat mit
  neuer belastbarer End-to-End-Evidenz.

Eine geplante Aufgabe darf monatlich nur den Research-Report oder einen
isolierten Draft-PR vorbereiten. Sie darf nie selbst mergen, taggen, releasen,
installieren oder Secrets verwenden. Fuer lokale Projekte sollte sie in einem
neuen Worktree laufen, damit laufende Arbeit unangetastet bleibt. Laut
[offizieller OpenAI-Dokumentation](https://learn.chatgpt.com/docs/automations)
werden solche Scheduled Tasks in ChatGPT Web oder der Desktop-App verwaltet;
lokale Projektaufgaben brauchen einen eingeschalteten Rechner und die laufende
Desktop-App.

## 6. Die wichtigsten manuellen Kontrollbefehle

```bash
scripts/research-check.sh --json
scripts/release-payload.sh
./scripts/check-docs.sh
git diff --check
git status --short
git rev-parse HEAD
```

Fuer einen Release-Kandidaten zusaetzlich:

```bash
./tests/run.sh
./tests/run-powershell.sh
```

Der kanonische technische Detailprozess bleibt in
[`docs/OPERATIONS.md`](docs/OPERATIONS.md) und
[`docs/RELEASE.md`](docs/RELEASE.md). Dieses Dokument ist der einfache Einstieg
fuer Menschen, die nach laengerer Pause zurueckkehren.
