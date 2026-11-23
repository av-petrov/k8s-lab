#!/bin/bash
# Однократная подготовка GCP для kind-dev01 (запускать в своём терминале, нужен gcloud login):
#   - API: Cloud Logging, Secret Manager
#   - SA kind-dev01-audit с единственной ролью roles/logging.logWriter (для Fluent Bit)
# Идемпотентно: существующие объекты не пересоздаются.
set -o errexit -o nounset -o pipefail
: "${GCP_PROJECT:?задайте GCP_PROJECT (или .local/config.env)}"
SA=kind-dev01-audit
SA_EMAIL="$SA@$GCP_PROJECT.iam.gserviceaccount.com"

gcloud services enable logging.googleapis.com secretmanager.googleapis.com --project "$GCP_PROJECT"
gcloud iam service-accounts describe "$SA_EMAIL" --project "$GCP_PROJECT" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA" --project "$GCP_PROJECT" --display-name "kind-dev01 audit shipper"
# Только что созданный SA становится виден IAM-политике проекта не сразу (eventual consistency):
# первая попытка часто падает с "Service account ... does not exist". Повторяем до ~2 минут.
for i in $(seq 1 12); do
  if ERR="$(gcloud projects add-iam-policy-binding "$GCP_PROJECT" --member "serviceAccount:$SA_EMAIL" \
              --role roles/logging.logWriter --condition=None 2>&1 >/dev/null)"; then
    break
  fi
  case "$ERR" in
    *"does not exist"*) [ "$i" -lt 12 ] || { echo "$ERR" >&2; exit 1; } ;;
    *) echo "$ERR" >&2; exit 1 ;;
  esac
  echo "SA ещё не виден IAM, повтор через 10с ($i/12)..."; sleep 10
done
echo "GCP готов: $SA_EMAIL (roles/logging.logWriter). Рекомендуется budget alert на проект."
