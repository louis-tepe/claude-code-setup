Yo ! Je t'envoie ma config Claude Code optimisee.

Le principe : un proxy local qui fait tourner Opus 4.6 (le plus intelligent) comme cerveau principal via ton abo Claude Max, et redirige les sous-taches vers GLM-5 (modele chinois gratuit). Resultat : tu utilises quasiment pas ton quota hebdomadaire Claude.

Pour installer (5 min) :

1. Il te faut un Mac (ou Linux) avec Python 3.10+ et un abonnement Claude Max
2. Installe Claude Code si c'est pas fait : npm install -g @anthropic-ai/claude-code
3. Je t'envoie la cle API Z.AI par message separe (ne la partage pas)
4. Puis :

git clone git@github.com:louis-tepe/claude-code-setup.git ~/claude-code-setup
cd ~/claude-code-setup
./install.sh
source ~/.zshrc
claude login
claude

Le script te demandera la cle API Z.AI pendant l'installation. Le proxy demarre tout seul quand tu lances claude.

Pour mettre a jour plus tard : cd ~/claude-code-setup && ./update.sh

Le guide complet est dans le repo : https://github.com/louis-tepe/claude-code-setup
