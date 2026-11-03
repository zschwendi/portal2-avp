#pragma once
// Porte d'entrée du contenu du joueur (runtime/content_check.h) avant le
// moteur, appelée par ios/main_ios.c sur le thread principal (SDL_main).
// Contenu complet : retour immédiat. Sinon, écran d'installation natif
// (UIKit : ce qui manque, espace libre, copie par le Finder ou
// tools/ios_device.sh data, bouton « Vérifier à nouveau ») ; la boucle
// d'exécution tourne jusqu'à ce qu'une vérification réussisse : le moteur ne
// démarre jamais avec des archives VPK manquantes ou tronquées.
// game, linux_root, prep : racines que le moteur utilisera (NULL : absente).
// documents : dossier de Documents/portal2-setup-status.json, écrit à chaque
// vérification.
void rt_ios_content_gate(const char *game, const char *linux_root, const char *prep, const char *documents);
