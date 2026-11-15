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
gcloud projects add-iam-policy-binding "$GCP_PROJECT" --member "serviceAccount:$SA_EMAIL" \
  --role roles/logging.logWriter --condition=None >/dev/null
echo "GCP готов: $SA_EMAIL (roles/logging.logWriter). Рекомендуется budget alert на проект."
