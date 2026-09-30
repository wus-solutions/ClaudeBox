# Skills

Skills, die in **jedem** Agenten dieses Containers verfügbar sein sollen.
Eine Datei je Skill: `skills/<name>/SKILL.md`.

Beim Start spiegelt der Entrypoint dieses Verzeichnis nach
`/home/dev/.claude/skills/`.

## Die drei Wege im Vergleich

| Weg | Wo | Wann sinnvoll |
|---|---|---|
| **Projekt-Skill** | `.claude/skills/` im geklonten Repo | repo-spezifisch; kommt automatisch mit, hier ist nichts zu tun |
| **Container-Skill** | dieses Verzeichnis | gilt für alle Agenten und alle Projekte, versioniert |
| **Laufzeit-Skill** | direkt in `~/.claude/skills/` im Terminal | zum Ausprobieren |

Ganze Plugins wie Superpowers gehören nicht hierher, sondern in `plugins.txt`
im Wurzelverzeichnis: Sie bringen Hooks mit, und ihre Skills rufen einander
über den Plugin-Namen auf. Siehe den Abschnitt *Skills* im Haupt-README.

## Warum Laufzeit allein nicht reicht

`~/.claude` ist ein Volume, ein dort angelegter Skill überlebt also Neustarts.
Aber ein Redeploy mit frischem Volume nimmt ihn mit — und zwar **still**. Der
Agent meldet nichts, er verhält sich ab dann nur anders. Wer in einem halben
Jahr wissen will, warum, findet keine Historie.

Deshalb: zum Erproben gern im Volume, alles Bleibende hierher.

## Verhalten beim Spiegeln

Der Entrypoint **kopiert nur hinein und löscht nichts**. Ein zur Laufzeit
angelegter Skill bleibt also erhalten. Trägt gleichzeitig ein Skill im Repo
denselben Namen, gewinnt das Repo — damit das Verhalten nach einem Deploy
vorhersagbar ist.

## Aufbau eines Skills

```
skills/mein-skill/SKILL.md
```

```markdown
---
name: mein-skill
description: Wann dieser Skill greifen soll — hieran entscheidet Claude, ob er ihn lädt.
---

# Mein Skill

Anleitung ...
```

Die `description` ist der wichtigste Teil: Sie ist das Einzige, was Claude
sieht, bevor er sich entscheidet, den Skill zu laden.
