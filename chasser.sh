#!/usr/bin/env bash
# Chasse les VM gratuites manquantes, une seule boucle pour tout le compte (deux boucles
# en parallèle se gênent : Oracle limite le débit de lancement par utilisateur).
#
#   netbox         VM.Standard.E2.1.Micro (Ubuntu 24.04), pour deploy/netbox d'Audit-HBO ;
#                  Tailscale s'installe au premier démarrage avec la clé TS_AUTHKEY.
#   audit-hbo-arm  VM.Standard.A1.Flex 1/6 ou 2/12 (limite gratuite : 2 cœurs / 12 Go).
#
# Les cibles manquantes sont essayées à tour de rôle. Cadence adaptative : l'intervalle
# (120 s au départ et au minimum) s'allonge d'une minute à chaque refus 429 et raccourcit
# de 10 s à chaque réponse normale. Arrêt en échec si une autre erreur se répète.
#
# Entrées (environnement) : COMPARTMENT SUBNET AD ARM_IMAGE, NETBOX_USER_DATA (fichier,
# absent : cible netbox ignorée), DUREE_MIN (330), GITHUB_OUTPUT. Sorties : created=<noms>,
# remaining=<noms>.
set -uo pipefail
DUREE_MIN=${DUREE_MIN:-330}
deadline=$(( $(date +%s) + DUREE_MIN * 60 ))
OUT=${GITHUB_OUTPUT:-/dev/null}
MICRO=VM.Standard.E2.1.Micro
MAX_MICRO=2

vivantes() {  # JSON des instances non supprimées du compartiment
  oci --no-retry compute instance list -c "$COMPARTMENT" --all \
    --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`].{n:"display-name",s:shape}' \
    2>/dev/null
}

# Liste illisible : arrêt, plutôt que de croire qu'aucune VM n'existe et d'en créer un doublon.
instances=$(vivantes) && echo "${instances:-[]}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  || { echo "::error::Liste des VM illisible chez Oracle : passage arrêté."; exit 1; }
instances=${instances:-[]}
existe() { echo "$instances" | python3 -c 'import json,sys; sys.exit(0 if any(i["n"] == sys.argv[1] for i in json.load(sys.stdin)) else 1)' "$1"; }

cibles=()
if existe audit-hbo-arm; then echo "audit-hbo-arm existe déjà."; else cibles+=(audit-hbo-arm); fi
if [ -z "${NETBOX_USER_DATA:-}" ] || [ ! -s "${NETBOX_USER_DATA:-/nonexistent}" ]; then
  echo "netbox ignorée : secret TS_AUTHKEY absent."
elif existe netbox; then
  echo "netbox existe déjà."
else
  micros=$(echo "$instances" | python3 -c 'import json,sys; print(sum(i["s"] == sys.argv[1] for i in json.load(sys.stdin)))' "$MICRO")
  if [ "$micros" -ge "$MAX_MICRO" ]; then
    echo "netbox ignorée : déjà $micros VM $MICRO (gratuit : $MAX_MICRO)."
  else
    netbox_image=$(oci --no-retry compute image list -c "$COMPARTMENT" --operating-system "Canonical Ubuntu" \
      --operating-system-version "24.04" --shape "$MICRO" --sort-by TIMECREATED --sort-order DESC --all \
      --query 'data[?!contains("display-name", `Minimal`) && !contains("display-name", `aarch64`)] | [0].id' \
      --raw-output 2>/dev/null)
    if [[ "$netbox_image" == ocid1.image.* ]]; then cibles+=(netbox); else echo "netbox ignorée : image Ubuntu 24.04 introuvable."; fi
  fi
fi

preparer() {  # $1 cible, $2 rang de l'essai : fixe nom, cpu, mem (hors sous-shell)
  if [ "$1" = netbox ]; then nom="NetBox (Micro)"; return; fi
  if [ $(( $2 % 2 )) -eq 0 ]; then cpu=1; mem=6; else cpu=2; mem=12; fi
  nom="ARM $cpu cœurs / $mem Go"
}

lancer() {  # $1 cible ; appelée dans $(…) : n'y fixer aucune variable
  case "$1" in
    audit-hbo-arm)
      oci --no-retry compute instance launch -c "$COMPARTMENT" --availability-domain "$AD" \
        --display-name audit-hbo-arm --hostname-label audit-hbo-arm --boot-volume-size-in-gbs 50 \
        --subnet-id "$SUBNET" --assign-public-ip true --private-ip 10.0.1.50 --ssh-authorized-keys-file ssh_key.pub \
        --user-data-file cloud-init.yaml --instance-options '{"areLegacyImdsEndpointsDisabled":true}' \
        --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$cpu,\"memoryInGBs\":$mem}" \
        --image-id "$ARM_IMAGE" --query 'data.id' --raw-output 2>&1 ;;
    netbox)
      oci --no-retry compute instance launch -c "$COMPARTMENT" --availability-domain "$AD" \
        --display-name netbox --subnet-id "$SUBNET" --assign-public-ip true --ssh-authorized-keys-file ssh_key.pub \
        --user-data-file "$NETBOX_USER_DATA" --shape "$MICRO" --image-id "$netbox_image" \
        --query 'data.id' --raw-output 2>&1 ;;
  esac
}

creees=()
declare -A rang=()
i=0; tries=0; refused=0; other=0; interval=120
while [ "${#cibles[@]}" -gt 0 ] && [ "$(date +%s)" -lt "$deadline" ]; do
  cible=${cibles[$(( i % ${#cibles[@]} ))]}
  r=${rang[$cible]:-0}
  tries=$((tries + 1))
  preparer "$cible" "$r"
  out=$(lancer "$cible") || true
  id=$(echo "$out" | grep -o 'ocid1\.instance[^ "]*' | head -1)
  if [ -n "$id" ]; then
    echo "$(date -u +%H:%M:%S) essai $tries — Créée : $cible ($nom)"
    creees+=("$cible")
    restantes=(); for c in "${cibles[@]}"; do [ "$c" = "$cible" ] || restantes+=("$c"); done
    cibles=("${restantes[@]+"${restantes[@]}"}")
    # Prévenir tout de suite (issue, donc e-mail), sans attendre la fin du passage.
    [ -n "${ON_CREATED:-}" ] && "$ON_CREATED" "$cible" "$id"
    sleep "$interval"; continue
  fi
  msg=$(echo "$out" | grep -o '"message": "[^"]*"' | head -1)
  echo "$(date -u +%H:%M:%S) essai $tries (intervalle ${interval} s) — $nom : ${msg:-$(echo "$out" | tail -1)}"
  case "$out" in
    *TooManyRequests*|*"Too many requests"*)
      other=0; refused=$((refused + 1))  # même cible et même taille au prochain essai
      interval=$(( interval + 60 > 600 ? 600 : interval + 60 ));;
    *"Out of host capacity"*|*InternalError*|*"Service unavailable"*)
      other=0; rang[$cible]=$((r + 1)); i=$((i + 1))
      interval=$(( interval - 10 < 120 ? 120 : interval - 10 ));;
    *) other=$((other + 1)); rang[$cible]=$((r + 1)); i=$((i + 1))
       if [ "$other" -ge 5 ]; then echo "::error::Erreur répétée, robot arrêté : ${msg:-$(echo "$out" | tail -1)}"; exit 1; fi;;
  esac
  sleep $(( interval + RANDOM % 10 ))
done

echo "created=${creees[*]+"${creees[*]}"}" >> "$OUT"
echo "remaining=${cibles[*]+"${cibles[*]}"}" >> "$OUT"
echo "Fin du passage : $tries essais dont $refused refusés (429). Créées : ${creees[*]:-aucune}. Restantes : ${cibles[*]:-aucune}."
