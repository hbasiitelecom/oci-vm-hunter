#!/usr/bin/env bash
# Appelé par chasser.sh dès qu'une VM est créée : issue GitHub (donc e-mail).
set -uo pipefail
cible=$1; id=$2
sleep 45
ip=$(oci compute instance list-vnics --instance-id "$id" --query 'data[0]."private-ip"' --raw-output 2>/dev/null || echo "?")
forme=$(oci compute instance get --instance-id "$id" --query 'data.shape' --raw-output 2>/dev/null || echo "?")
case "$cible" in
  netbox)
    titre="VM netbox créée ($forme, IP interne $ip)"
    corps="La VM NetBox est créée. Tailscale s'installe au premier démarrage (10 à 30 min). Sur le Mac, à la racine d'Audit-HBO :

    NETBOX_OCI_COMPARTIMENT=\$(sed -n 's/^COMPARTMENT=//p' ~/.oci/audit-hbo/ids.env) NETBOX_OCI_MODELE=audit-hbo deploy/netbox/tout-installer.sh

Le script voit que la VM existe et passe à l'installation de NetBox." ;;
  *)
    titre="VM ARM audit-hbo-arm créée ($forme, IP interne $ip)"
    corps="La VM ARM est créée : forme $forme, IP interne $ip. Reviens dans la session Claude et dis « la VM ARM est créée » pour migrer Audit HBO." ;;
esac
gh issue create --repo "$GITHUB_REPOSITORY" --title "$titre" --body "$corps" >/dev/null && echo "Issue ouverte : $titre"
