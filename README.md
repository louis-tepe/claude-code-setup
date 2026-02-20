# Claude Code Setup — GLM-5 Proxy

Configuration Claude Code optimisee avec routage intelligent :
- **Opus 4.6** (abonnement Claude Max) comme agent principal / cerveau
- **GLM-5** (Zhipu AI / Z.AI) comme workers / subagents (remplace Sonnet et Haiku)

## Pre-requis

- **macOS** (le script utilise `afplay`, `lsof`, `brew`)
- **Python 3.9+** avec pip
- **jq** (`brew install jq`)
- **Claude Code** installe et connecte (`claude login`)
- **Abonnement Claude Max** (pour Opus 4.6)

## Installation

```bash
git clone <ce-repo> ~/claude-code-setup
cd ~/claude-code-setup
chmod +x install.sh
./install.sh
```

Le script installe automatiquement :
1. Le proxy GLM-5 dans `~/claude-code-proxy/`
2. La configuration Claude Code dans `~/.claude/`
3. L'integration shell dans `~/.zshrc`

## Architecture

```
                    Claude Code
                        |
                  localhost:8082
                        |
                   [GLM-5 Proxy]
                   /     |     \
                  /      |      \
           Opus 4.6   Sonnet   Haiku
              |          |        |
         Anthropic    Z.AI     Z.AI
         (OAuth)     (GLM-5)  (GLM-5)
```

### Fallbacks automatiques vers Anthropic

Certaines features ne sont pas supportees par Z.AI et sont automatiquement redirigees vers Anthropic :
- `web_search` (recherche web)
- `vision/image` (analyse d'images)
- `forced_tool_choice` (choix d'outil force)
- Erreurs serveur Z.AI (code 500)

## Ce qui est installe

### Proxy (`~/claude-code-proxy/`)
- `proxy.py` — Proxy FastAPI avec routage intelligent
- `.env` — Cle API Z.AI (partagee)
- `venv/` — Environnement Python isole

### Config Claude Code (`~/.claude/`)
- `settings.json` — Config globale (env vars, hooks, plugins, statusline)
- `statusline-command.sh` — Barre de statut personnalisee (modele, contexte, cout)
- `agents/` — 7 agents custom (Bash, Explore, Plan, etc.)

### Shell (`~/.zshrc`)
- `ANTHROPIC_BASE_URL` pointe vers le proxy local
- Fonction `claude()` qui demarre le proxy automatiquement
- Alias `cc` pour le mode dangereux

## Utilisation

```bash
# Lancer Claude Code (le proxy demarre automatiquement)
claude

# Verifier le proxy
curl http://localhost:8082/health

# Voir les logs du proxy
tail -f /tmp/claude-proxy.log

# Demarrer le proxy manuellement
~/claude-code-proxy/start-proxy.sh
```

## Plugins

Apres l'installation, activez les plugins :

```bash
claude plugins:install feature-dev@claude-plugins-official
claude plugins:install code-review@claude-plugins-official
claude plugins:install commit-commands@claude-plugins-official
claude plugins:install security-guidance@claude-plugins-official
claude plugins:install hookify@claude-plugins-official
claude plugins:install frontend-design@claude-plugins-official
```

## Desinstallation

```bash
# Supprimer le proxy
rm -rf ~/claude-code-proxy

# Retirer le bloc shell (entre les marqueurs CLAUDE CODE PROXY)
# Editer ~/.zshrc et supprimer le bloc

# Restaurer la config Claude Code
# Le backup est dans ~/.claude/settings.json.backup.*
```
