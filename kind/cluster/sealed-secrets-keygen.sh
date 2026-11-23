#!/bin/bash
# Однократно (или при ротации): своя пара ключей Sealed Secrets.
#   - приватный ключ генерируется в памяти и НЕ пишется на диск;
#   - публичный сертификат -> sealed-secrets/sealed-secrets.crt (коммитится; им запечатывают офлайн);
#   - готовый манифест Secret (kube-system, label active) -> новая версия в GCP Secret Manager;
#   - если задан SOPS_BACKUP_FILE — тот же манифест, зашифрованный sops (SOPS_ARGS, например "--pgp <FPR>").
# Запуск: make sealed-secrets-keygen [SOPS_BACKUP_FILE=... SOPS_ARGS=...]
set -o errexit -o nounset -o pipefail
: "${GCP_PROJECT:?задайте GCP_PROJECT (или .local/config.env)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SM_SECRET=sealed-secrets-key
CRT="$ROOT/sealed-secrets/sealed-secrets.crt"

if gcloud secrets versions list "$SM_SECRET" --project "$GCP_PROJECT" --filter=state=ENABLED --format='value(name)' 2>/dev/null | grep -q .; then
  if [ "${FORCE:-}" != 1 ]; then
    echo "В Secret Manager уже есть активный ключ $SM_SECRET. Новый ключ = ротация: все SealedSecret придётся перезапечатать." >&2
    echo "Если это осознанно: FORCE=1 make sealed-secrets-keygen" >&2
    exit 1
  fi
fi

KEY="$(openssl genrsa 4096 2>/dev/null)"
printf '%s\n' "$KEY" | openssl req -x509 -new -key /dev/stdin -days 3650 -sha256 \
  -subj "/CN=sealed-secrets/O=k8s-lab-kind-dev01" -out "$CRT"

manifest() {
  cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: sealed-secrets-key-byo
  namespace: kube-system
  labels:
    sealedsecrets.bitnami.com/sealed-secrets-key: active
type: kubernetes.io/tls
data:
  tls.crt: $(base64 < "$CRT" | tr -d '\n')
  tls.key: $(printf '%s\n' "$KEY" | base64 | tr -d '\n')
YAML
}

# Бэкап — ДО загрузки в Secret Manager: ключ не должен оказаться в облаке без резервной копии.
# Пишем во временный файл рядом с целевым и переименовываем только при успехе (без пустых файлов при ошибке).
if [ -n "${SOPS_BACKUP_FILE:-}" ]; then
  [ -n "${SOPS_ARGS:-}" ] || [ -n "${SOPS_CONFIG:-}" ] || {
    echo 'нужен SOPS_ARGS (например SOPS_ARGS="--pgp <FPR>"): stdin не совпадает с creation_rules .sops.yaml' >&2; exit 1; }
  trap 'rm -f "$SOPS_BACKUP_FILE.tmp"' EXIT
  # shellcheck disable=SC2086
  manifest | sops --encrypt ${SOPS_ARGS:-} --encrypted-regex '^(data|stringData)$' \
    --input-type yaml --output-type yaml /dev/stdin > "$SOPS_BACKUP_FILE.tmp"
  mv "$SOPS_BACKUP_FILE.tmp" "$SOPS_BACKUP_FILE"
  echo "Резервная копия (sops): $SOPS_BACKUP_FILE"
else
  echo "ВНИМАНИЕ: без SOPS_BACKUP_FILE резервной копии не будет. Позже: make sealed-secrets-backup SOPS_BACKUP_FILE=... SOPS_ARGS=..." >&2
fi

if ! gcloud secrets describe "$SM_SECRET" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  # version-destroy-ttl: уничтожение версии откладывается на 30 дней (защита от случайного destroy).
  gcloud secrets create "$SM_SECRET" --project "$GCP_PROJECT" --replication-policy=automatic \
    --version-destroy-ttl=2592000s --labels=cluster=kind-dev01,purpose=sealed-secrets
fi
manifest | gcloud secrets versions add "$SM_SECRET" --project "$GCP_PROJECT" --data-file=- >/dev/null
echo "Ключ загружен в Secret Manager: $SM_SECRET (новая версия). Сертификат: $CRT"
unset KEY
