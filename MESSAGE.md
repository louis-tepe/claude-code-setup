Yo ! Je t'envoie ma config Claude Code optimisée.

Le principe : un proxy local qui fait tourner Opus 4.6 (le plus intelligent) comme cerveau principal via ton abo Claude Max, et redirige les sous-tâches vers GLM-5 (modèle chinois gratuit). Résultat : tu utilises quasiment pas ton quota hebdomadaire Claude.

Pour installer (5 min) :

1. Il te faut un Mac avec Python 3 et un abonnement Claude Max
2. Installe Claude Code si c'est pas fait : npm install -g @anthropic-ai/claude-code
3. Puis :

git clone git@github.com:louis-tepe/claude-code-setup.git ~/claude-code-setup
cd ~/claude-code-setup
./install.sh
source ~/.zshrc
claude login
claude

C'est tout, le proxy démarre tout seul quand tu lances claude.

Le guide complet est dans le repo : https://github.com/louis-tepe/claude-code-setup
