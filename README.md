# oci-vm-hunter

Robot GitHub Actions : crée les VM Oracle Always Free manquantes (eu-paris-1) dès qu'Oracle a
de la place, avec **une seule boucle** pour tout le compte (`chasser.sh`), car Oracle limite
le débit de lancement par utilisateur.

| VM | Forme | Usage |
| --- | --- | --- |
| `netbox` | VM.Standard.E2.1.Micro | NetBox (`deploy/netbox` d'Audit-HBO) ; Tailscale au premier démarrage |
| `audit-hbo-arm` | VM.Standard.A1.Flex 1/6 ou 2/12 | Remplaçante d'Audit-HBO (limite gratuite : 2 cœurs / 12 Go) |

- ~1 essai toutes les 2 minutes, cibles à tour de rôle ; l'intervalle s'allonge à chaque refus
  « trop de requêtes » (429) et se resserre ensuite. Passages de 5 h 30, relancés seuls ; cron
  horaire en secours.
- Chaque VM créée : issue (e-mail GitHub, `prevenir.sh`). Toutes créées : robot désactivé.
- Erreur répétée autre que le manque de place, ou liste des VM illisible : passage en échec.

Secrets : `OCI_KEY`, `OCI_USER`, `OCI_FINGERPRINT`, `OCI_TENANCY`, `OCI_REGION`,
`OCI_COMPARTMENT`, `OCI_SUBNET`, `OCI_AD`, `OCI_ARM_IMAGE`, et `TS_AUTHKEY` (clé Tailscale à
usage unique pour la VM NetBox ; sans elle, seule la VM ARM est cherchée).
