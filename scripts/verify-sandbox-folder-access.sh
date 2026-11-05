#!/bin/bash
# Vérification manuelle (macOS) : ouverture d'un dossier autorisé sous un profil de bac à sable qui interdit ses parents.
#
# Contexte (Mission 005) : le bac à sable de l'application n'autorise que le dossier choisi dans le sélecteur et son contenu,
# pas ses dossiers parents. Un parcours depuis « / » (openat composant par composant) échoue donc, même avec O_EVTONLY,
# et `realpath` échoue aussi. L'ouverture directe + F_GETPATH sur le descripteur fonctionne.
# Ce script reproduit la situation avec `sandbox-exec` (émulation fidèle sur ce point, pas l'App Sandbox complet).
#
# Résultat attendu :   A (parcours depuis /) = ÉCHEC   B (ouverture directe) = OK   realpath = refusé   F_GETPATH = OK
set -euo pipefail
base="$(mktemp -d /private/tmp/ghost-sbx.XXXXXX)"
trap 'rm -rf "$base"' EXIT
mkdir -p "$base/outer/granted" && echo hello > "$base/outer/granted/a.csv"

cat > "$base/t.c" <<'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/stat.h>
static int walk(const char *path) {            /* A : parcours depuis « / » */
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    char *copy = strdup(path), *save = NULL;
    for (char *c = strtok_r(copy, "/", &save); c; ) {
        char *next = strtok_r(NULL, "/", &save);
        int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
        if (next) flags = O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
        int n = openat(fd, c, flags); close(fd);
        if (n < 0) { free(copy); return -1; }
        fd = n; c = next;
    }
    free(copy); return fd;
}
int main(int argc, char **argv) {
    const char *p = argv[1];
    int a = walk(p);
    int b = open(p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);   /* B : ouverture directe */
    char *rp = realpath(p, NULL);
    char buf[PATH_MAX]; int g = (b >= 0 && fcntl(b, F_GETPATH, buf) == 0);
    printf("A parcours depuis /   : %s\n", a >= 0 ? "OK" : "ECHEC");
    printf("B ouverture directe   : %s\n", b >= 0 ? "OK" : "ECHEC");
    printf("realpath              : %s\n", rp ? "OK" : "refuse");
    printf("F_GETPATH (descripteur): %s\n", g ? buf : "ECHEC");
    return 0;
}
EOF
clang -o "$base/t" "$base/t.c"
cat > "$base/p.sb" <<EOF
(version 1)
(allow default)
(deny file-read* (literal "$base") (literal "$base/outer"))
(allow file-read* file-write* (subpath "$base/outer/granted"))
EOF
echo "=== sans bac à sable ===";                     "$base/t" "$base/outer/granted"
echo "=== profil interdisant les dossiers parents ==="; sandbox-exec -f "$base/p.sb" "$base/t" "$base/outer/granted"
