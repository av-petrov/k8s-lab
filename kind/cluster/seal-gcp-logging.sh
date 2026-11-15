#!/bin/bash
# Новый ключ SA kind-dev01-audit -> сразу в SealedSecret audit-logging/gcp-logging-sa (офлайн, по сертификату).
# Открытый ключ существует только в пайпе. Результат коммитится:
#   audit/shipper/secrets/gcp-logging-sa.sealed.yaml
# Ротация: запустить ещё раз -> commit/push -> Argo CD обновит Secret -> удалить старый ключ SA в GCP.
set -o errexit -o nounset -o pipefail
: "${GCP_PROJECT:?задайте GCP_PROJECT (или .local/config.env)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRT="$ROOT/sealed-secrets/sealed-secrets.crt"
OUT="$ROOT/audit/shipper/secrets/gcp-logging-sa.sealed.yaml"
[ -s "$CRT" ] || { echo "нет $CRT: сначала make sealed-secrets-keygen" >&2; exit 1; }
trap 'rm -f "$OUT.tmp"' EXIT

gcloud iam service-accounts keys create /dev/stdout --project "$GCP_PROJECT" \
    --iam-account "kind-dev01-audit@$GCP_PROJECT.iam.gserviceaccount.com" 2>/dev/null \
  | kubectl --context kind-dev01 create secret generic gcp-logging-sa -n audit-logging \
      --from-file=key.json=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert "$CRT" --format yaml > "$OUT.tmp"
grep -q 'encryptedData' "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Готово: $OUT. Ключи SA в GCP: gcloud iam service-accounts keys list --iam-account kind-dev01-audit@$GCP_PROJECT.iam.gserviceaccount.com"
