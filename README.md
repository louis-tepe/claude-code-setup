# Claude Code Setup — GLM-5 Proxy

> Utilise Claude Code comme un pro : **Opus 4.6** comme cerveau principal + **GLM-5** comme workers pour les sous-tâches. Résultat : un agent IA puissant sans exploser les limites hebdomadaires de ton abonnement Claude.

## Comment ça marche ?

Claude Code utilise 3 niveaux de modèles :
- **Opus** — l'agent principal, celui qui réfléchit et orchestre (le plus intelligent)
- **Sonnet** — les sous-agents qui exécutent les tâches (recherche, exploration, etc.)
- **Haiku** — les micro-tâches rapides (résumés, validations)

Le problème : tout passe par Anthropic, et tu peux vite atteindre les limites hebdomadaires.

**La solution** : un proxy local qui redirige Sonnet et Haiku vers GLM-5 (modèle chinois de Zhipu AI, gratuit via Z.AI), tout en gardant Opus sur ton abonnement Claude Max.

```
Claude Code
    |
localhost:8082
    |
[Proxy local]
    |
    |--- Opus ---------> Anthropic (ton abonnement Max)
    |--- Sonnet -------> Z.AI GLM-5 (gratuit)
    |--- Haiku --------> Z.AI GLM-5 (gratuit)
```

Les features incompatibles avec GLM-5 (recherche web, vision, etc.) sont automatiquement renvoyées vers Anthropic.

---

## Pré-requis

Avant de commencer, assure-toi d'avoir :

| Pré-requis | Comment vérifier | Comment installer |
|------------|-----------------|-------------------|
| **macOS** | Tu es sur Mac | - |
| **Python 3.9+** | `python3 --version` | `brew install python3` |
| **jq** | `jq --version` | `brew install jq` |
| **Homebrew** | `brew --version` | [brew.sh](https://brew.sh) |
| **Claude Code** | `claude --version` | `npm install -g @anthropic-ai/claude-code` |
| **Abonnement Claude Max** | [claude.ai/settings](https://claude.ai/settings) | [claude.ai/upgrade](https://claude.ai/upgrade) |

---

## Installation (5 minutes)

### Étape 1 — Clone le repo

```bash
git clone git@github.com:louis-tepe/claude-code-setup.git ~/claude-code-setup
```

### Étape 2 — Lance l'installateur

```bash
cd ~/claude-code-setup
./install.sh
```

Le script va :
1. Vérifier que tu as Python, jq, etc.
2. Installer le proxy dans `~/claude-code-proxy/` (avec son environnement Python isolé)
3. Copier la config Claude Code (settings, agents, statusline)
4. Ajouter l'intégration shell dans ton `~/.zshrc`
5. Tester que le proxy fonctionne

### Étape 3 — Recharge ton terminal

```bash
source ~/.zshrc
```

### Étape 4 — Connecte-toi à Claude

```bash
claude login
```

Connecte-toi avec ton compte Claude Max.

### Étape 5 — Lance Claude Code

```bash
claude
```

C'est tout. Le proxy démarre automatiquement en arrière-plan.

---

## Installer les plugins (optionnel mais recommandé)

Ces plugins ajoutent des fonctionnalités utiles à Claude Code :

```bash
claude plugins:install feature-dev@claude-plugins-official
claude plugins:install code-review@claude-plugins-official
claude plugins:install commit-commands@claude-plugins-official
claude plugins:install security-guidance@claude-plugins-official
claude plugins:install hookify@claude-plugins-official
claude plugins:install frontend-design@claude-plugins-official
```

---

## Vérifier que tout fonctionne

### Le proxy tourne ?

```bash
curl http://localhost:8082/health
```

Tu devrais voir :
```json
{
  "status": "healthy",
  "target_model": "glm-5",
  "routing": {
    "opus": "Anthropic (OAuth)",
    "sonnet": "Z.AI",
    "haiku": "Z.AI"
  }
}
```

### Voir les logs en temps réel

```bash
tail -f /tmp/claude-proxy.log
```

Tu verras les requêtes routées avec des couleurs :
- Cyan : routage (quel modèle va où)
- Vert : requête réussie
- Jaune : fallback vers Anthropic
- Rouge : erreur

---

## Ce qui est installé

```
~/claude-code-proxy/          # Le proxy
├── proxy.py                  # Serveur FastAPI
├── .env                      # Clé API Z.AI
├── start-proxy.sh            # Démarrage manuel
└── venv/                     # Python isolé

~/.claude/                    # Config Claude Code
├── settings.json             # Réglages globaux
├── statusline-command.sh     # Barre de statut custom
└── agents/                   # 7 agents spécialisés
    ├── Bash.md               # Exécution de commandes
    ├── Explore.md            # Exploration de code
    ├── Plan.md               # Architecture (utilise Opus)
    ├── claude-code-guide.md  # Guide Claude Code
    ├── general-purpose.md    # Agent polyvalent
    ├── magic-docs.md         # Documentation
    └── statusline-setup.md   # Config statusline

~/.zshrc                      # Intégration shell ajoutée
```

---

## Commandes utiles

| Commande | Description |
|----------|-------------|
| `claude` | Lancer Claude Code (proxy auto-start) |
| `cc` | Alias pour le mode sans confirmations |
| `curl localhost:8082/health` | Vérifier le proxy (routing, stats, circuit breaker) |
| `tail -f /tmp/claude-proxy.log` | Logs du proxy |
| `~/claude-code-proxy/start-proxy.sh` | Démarrer le proxy manuellement |
| `cd ~/claude-code-setup && ./update.sh` | Mettre à jour (pull + re-appliquer) |
| `cd ~/claude-code-setup && ./uninstall.sh` | Tout désinstaller proprement |

---

## Dépannage

### Le proxy ne démarre pas

```bash
# Vérifier si le port est utilisé
lsof -i:8082

# Regarder les logs d'erreur
cat /tmp/claude-proxy.log

# Relancer manuellement
~/claude-code-proxy/start-proxy.sh
```

### Claude Code ne se connecte pas

```bash
# Vérifier la variable d'environnement
echo $ANTHROPIC_BASE_URL
# Doit afficher : http://localhost:8082

# Se reconnecter
claude login
```

### Erreurs GLM-5

Le proxy inclut un **circuit breaker** : apres 5 echecs Z.AI consecutifs, il bascule automatiquement sur Anthropic pendant 2 minutes, puis re-teste. Visible dans `/health`.

---

## Mise a jour

Quand de nouvelles ameliorations sont publiees :

```bash
cd ~/claude-code-setup
./update.sh
```

Le script pull les derniers changements, met a jour le proxy et la config, et preserv ton `.env`.

---

## Desinstallation

```bash
cd ~/claude-code-setup
./uninstall.sh
```

Le script supprime proprement : proxy, agents, integration shell, service auto-start, et propose de restaurer ton ancien settings.json.

---

## Crédits

- Proxy basé sur [jodavan/claude-code-proxy](https://github.com/jodavan/claude-code-proxy), adapté pour le routage GLM-5
- Modèle GLM-5 par [Zhipu AI](https://z.ai)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) par Anthropic
