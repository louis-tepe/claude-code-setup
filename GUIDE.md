# Claude Code Multi-Provider Router — Guide Complet

## 1. Vue d'Ensemble

### Le probleme que ce projet resout

Claude Code est un agent IA qui aide les developpeurs a coder. Pour fonctionner, il communique avec l'API Anthropic en arriere-plan. Le probleme : **Anthropic est cher.**

| Modele | Entree ($/M tokens) | Sortie ($/M tokens) |
|---|---|---|
| Claude Opus 4.6 | $7.50 | $37.50 |
| Claude Sonnet 4.6 | $3.00 | $15.00 |
| Claude Haiku 4.5 | $1.00 | $5.00 |

Ce projet insere un **proxy local** entre Claude Code et les API des fournisseurs. Ce proxy redirige les requetes vers des modeles moins chers (Z.AI GLM, MiniMax, Xiaomi MiMo), tout en gardant Opus sur Anthropic. Resultat : une reduction massive des couts sans sacrifier la qualite.

### Ce que ce projet ajoute

- **7 modes de routage** : differents schemas de distribution entre fournisseurs
- **Un proxy local** : un serveur FastAPI qui intercepte et redirige les requetes
- **Des commandes shell** : `minimax-on`, `glm-on`, etc. pour changer de mode
- **De la transparence** : cout reel en temps reel, statistiques d'utilisation

---

## 2. Architecture

### Diagramme de flux

```
                         UTILISATEUR
                             |
                         "claude"
                             |
                 +-----------v-----------+
                 |  Shell wrapper (zshrc)  |
                 |  - Lit le mode courant  |
                 |  - Configure env vars   |
                 |  - Demarre le proxy     |
                 +-----------+-----------+
                             |
          [selon le mode : "off" ou "full" bypass complet]
                             |
              +--------------+--------------+
              |                             |
      [claude-full]               [tous les autres modes]
              |                             |
              v                             v
    ANTHROPIC (OAuth)            PROXY LOCAL (:8082)
    - Pas de proxy                     |
    - Natif                  +---------+---------+
                             |         |         |
                         SONNET    HAIKU      OPUS
                         (selon    (selon    (toujours
                          mode)     mode)    Anthropic)
                             |         |         |
                             v         v         v
                          Z.AI     MiniMax   ANTHROPIC
                        ou MiniMax  ou Z.AI   (OAuth)
```

### La separation en deux couches

**`~/.claude/`** = la telecommande (tes preferences, tes cles, tes choix)
- Jamais dans git, specifique a ta machine
- Contient les cles API (secrets), l'etat du mode, les fichiers de mode

**`claude-code-setup/`** = la tele (le hardware qui fait le travail)
- Versionne dans git, partageable, reutilisable
- Contient le proxy Python, le shell, l'installeur

Le proxy ne sait pas quel bouton tu as appuye. Il recoit juste "envoie ca a cette URL avec cette cle" et il le fait.

### Ce que le proxy fait techniquement

1. **Detecte le tier** du modele (opus, sonnet, haiku) via le nom du modele
2. **Choisit le provider** selon la configuration
3. **Sanitize la requete** : supprime les parametres incompatibles avec le provider
4. **Transmet** au provider et recoit la reponse en streaming
5. **Recalcule les couts** pour afficher le vrai prix dans Claude Code
6. **Circuit breaker** : si un provider echoue 5 fois, bascule sur Anthropic automatiquement

---

## 3. Les Fichiers Expliques

| Fichier | Role | Analogie |
|---------|------|----------|
| `proxy/proxy.py` | Serveur FastAPI qui route les requetes par tier | Le standard telephonique de l'hotel |
| `shell/claude-shell.sh` | Commandes shell + wrapper `claude()` | Le panneau de controle du chauffage |
| `proxy-modes/on.env` | Config du mode GLM hybride | La fiche d'abonnement chez l'operateur A |
| `proxy-modes/minimax.env` | Config du mode MiniMax hybride | La fiche d'abonnement chez l'operateur B |
| `proxy-modes/mix.env` | Config du mode split GLM+MiniMax | L'agenda avec 2 specialistes differents |
| `statusline-command.sh` | Barre de statut Claude Code | Le tableau de bord de la voiture |
| `install.sh` | Installeur automatique | Le technicien qui branche tout |

---

## 4. Les 7 Modes en Detail

| Mode | Sonnet | Haiku | Opus | Caching | Quand l'utiliser |
|---|---|---|---|---|---|
| `claude-full` | Anthropic | Anthropic | Anthropic | oui | 100% natif, debug |
| `glm-on` | GLM-5.1 | GLM-4.7 | Anthropic | non | Usage quotidien |
| `minimax-on` | M2.7 | M2.7 | Anthropic | oui | Max economie |
| `mimo-on` | MiMo-V2.5-Pro | MiMo-V2.5-Pro | Anthropic | oui | Token Plan Xiaomi (credits) |
| `mix-on` | GLM-5.1 | M2.7 | Anthropic | partiel | Optimal (qualite + cout) |
| `glm-full` | Z.AI direct | Z.AI direct | Z.AI direct | non | Z.AI only, pas d'Anthropic |
| `mimo-full` | MiMo direct | MiMo direct | MiMo direct | oui | Token Plan Xiaomi sur tous tiers |

### Comparaison des couts (pour 100k tokens in + 50k out)

| Mode | Cout Sonnet | Cout 10x Haiku | Total | Economie |
|---|---|---|---|---|
| `claude-full` | $1.05 | $3.50 | $4.55 | — |
| `glm-on` | $0.36 | $1.70 | $2.06 | -55% |
| `minimax-on` | $0.09 | $0.60 | $0.69 | -85% |
| `mimo-on` | $0.25 | $1.25 | $1.50 | -67% (PAYG, sinon forfait) |
| `mix-on` | $0.36 | $0.90 | $1.26 | -72% |

---

## 5. Le Systeme de Fichiers de Mode

### Format d'un fichier `.env`

```env
# Directives shell (NE sont PAS transmises au proxy)
_SHELL_SONNET_KEY=.zai-api-key        # Fichier de cle dans ~/.claude/
_SHELL_HAIKU_KEY=.minimax-api-key     # Fichier de cle dans ~/.claude/
_SHELL_DISABLE_CACHING_SONNET=1       # Desactive le cache pour Sonnet

# Variables proxy (transmises au processus Python)
SONNET_PROVIDER_BASE_URL=https://api.z.ai/api/anthropic
HAIKU_PROVIDER_BASE_URL=https://api.minimax.io/anthropic
PROVIDER_SONNET_MODEL=glm-5.1
PROVIDER_HAIKU_MODEL=MiniMax-M2.7
PROVIDER_PASS_CACHE_CONTROL=1
```

### Comment ca marche

La fonction `_proxy_start()` lit le fichier ligne par ligne :
- Lignes `_SHELL_*` → interpretees par le shell (injection de cles, caching)
- Autres lignes → passees comme variables d'environnement au proxy

Le code est **generique** : il ne connait pas les noms des providers. Ajouter un provider = creer un fichier `.env`, zero modification au code.

---

## 6. Le Flux d'une Requete

```
1. Tu tapes "claude" dans le terminal
2. Le wrapper shell() lit le mode dans ~/.claude/proxy-routing
3. Il demarre le proxy avec les bonnes env vars
4. Il exporte ANTHROPIC_BASE_URL=http://localhost:8082
5. Il lance le vrai "claude" binaire

6. Claude Code envoie : POST /v1/messages {"model": "claude-sonnet-4-6", ...}
7. Le proxy detecte le tier : "sonnet"
8. Il cherche la config provider pour "sonnet"
9. Il sanitize la requete (supprime les params incompatibles)
10. Il reecrit le modele : "claude-sonnet-4-6" → "MiniMax-M2.7"
11. Il transmet a https://api.minimax.io/anthropic/v1/messages
12. MiniMax repond en streaming
13. Le proxy recalcule les tokens pour afficher le bon cout
14. Claude Code recoit la reponse et l'affiche
```

---

## 7. Ajout d'un Nouveau Provider

Exemple avec un provider fictif "DeepSeek".

### Etape 1 : Stocker la cle API (1 min)
```bash
echo 'sk-deepseek-abc123' > ~/.claude/.deepseek-api-key
chmod 600 ~/.claude/.deepseek-api-key
```

### Etape 2 : Creer le fichier de mode (3 min)
```bash
cat > ~/.claude/proxy-modes/deepseek.env << 'EOF'
_SHELL_SONNET_KEY=.deepseek-api-key
_SHELL_HAIKU_KEY=.deepseek-api-key
_SHELL_DISABLE_CACHING_SONNET=1
_SHELL_DISABLE_CACHING_HAIKU=1
SONNET_PROVIDER_BASE_URL=https://api.deepseek.com/anthropic
HAIKU_PROVIDER_BASE_URL=https://api.deepseek.com/anthropic
PROVIDER_SONNET_MODEL=deepseek-r1-5
PROVIDER_HAIKU_MODEL=deepseek-r1-2
EOF
```

### Etape 3 : Ajouter les prix dans proxy.py (2 min)
```python
# Dans MODEL_PRICING, ajouter :
"deepseek-r1-5":  {"input": 0.14, "output": 0.28},
"deepseek-r1-2":  {"input": 0.05, "output": 0.10},
```

### Etape 4 : Ajouter la commande shell (1 min)
```bash
# Dans claude-shell.sh, ajouter :
deepseek-on() { _switch_mode deepseek; }
```

### Etape 5 : Tester
```bash
source ~/.zshrc
deepseek-on
claude
```

---

## 8. Glossaire

| Terme | Definition |
|-------|-----------|
| **Proxy** | Serveur intermediaire entre Claude Code et le provider. Transforme et redirige les requetes. |
| **Provider** | Fournisseur d'API LLM (Anthropic, Z.AI, MiniMax). Chacun a ses prix et limites. |
| **Tier** | Niveau de modele dans Claude Code : Opus (puissant), Sonnet (equilibre), Haiku (rapide). |
| **Mode** | Schema de routage predefini. Declare quel tier utilise quel provider. |
| **Circuit Breaker** | Protection : apres 5 echecs d'un provider, bascule automatiquement vers Anthropic pendant 120s. |
| **Sanitization** | Nettoyage de la requete pour la rendre compatible avec le provider cible. |
| **Fallback** | Repli automatique vers Anthropic quand un provider echoue. Transparent pour l'utilisateur. |
| **cache_control** | Mecanisme de reutilisation du cache de prompts. Supporte par MiniMax, pas par Z.AI. |
| **Token Scaling** | Recalcul des tokens pour afficher le cout reel du provider dans Claude Code. |
| **OAuth** | Authentification par session (compte Claude). Utilise pour Opus via abonnement Max. |
