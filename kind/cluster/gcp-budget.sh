#!/bin/bash
# Защита от выхода за бесплатный лимит GCP (Cloud Logging: 50 GiB/проект/месяц, дальше $0.50/GiB).
# Запускать в своём терминале (нужен gcloud login и права на billing-аккаунт): make gcp-budget
#
#   1. API Billing Budgets + Cloud Monitoring в проекте
#   2. канал уведомлений email (если задан ALERT_EMAIL)
#   3. alert policies по метрике logging.googleapis.com/billing/monthly_bytes_ingested: > 25 GiB и > 40 GiB
#      (gcp/monitoring/*.json) — срабатывают ДО появления затрат, в отличие от бюджета
#   4. бюджет на проект (BUDGET_AMOUNT в валюте billing-аккаунта, по умолчанию 1) с порогами 50%, 100%
#      и прогнозом 100%. Бюджет только оповещает, ничего не отключает.
# Аварийная остановка приёма логов: make gcp-logging-off (вернуть: make gcp-logging-on).
#
# Идемпотентно: существующие канал, политики и бюджет не пересоздаются и не меняются.
# Чтобы поменять существующие — удалить их в консоли и запустить снова.
# Настройки — .local/config.env (не в Git): GCP_PROJECT, BILLING_ACCOUNT, ALERT_EMAIL, [BUDGET_AMOUNT].
set -o errexit -o nounset -o pipefail
trap 'echo "!! ошибка: строка $LINENO, код $? — см. сообщение gcloud выше" >&2' ERR
: "${GCP_PROJECT:?задайте GCP_PROJECT (или .local/config.env)}"
: "${BILLING_ACCOUNT:?задайте BILLING_ACCOUNT (gcloud billing projects describe $GCP_PROJECT --format=value(billingAccountName))}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-1}"
BILLING_ACCOUNT="${BILLING_ACCOUNT#billingAccounts/}"   # принимаем и "billingAccounts/XXXX-..." и "XXXX-..."
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUDGET_NAME="kind-dev01 ($GCP_PROJECT)"
TMP="$ROOT/.build/gcp-monitoring"
mkdir -p "$TMP"

# `monitoring channels` есть только в beta (в GA — нет), `policies` — в GA и beta: используем beta для обоих.
# Автоопределение через `--help` ненадёжно: GA `gcloud monitoring channels --help` возвращает 0 при Invalid choice.
mon() { gcloud beta monitoring "$@" --project "$GCP_PROJECT"; }

echo ">> API: billingbudgets, monitoring"
gcloud services enable billingbudgets.googleapis.com monitoring.googleapis.com --project "$GCP_PROJECT"
mon channels list --limit=1 --format='value(name)' >/dev/null || {
  echo "нет gcloud beta monitoring channels: gcloud components install beta" >&2; exit 1; }

CHANNEL=""
if [ -n "$ALERT_EMAIL" ]; then
  CHANNEL="$(mon channels list --filter="type=\"email\" AND labels.email_address=\"$ALERT_EMAIL\"" \
               --format='value(name)' | head -1)"
  if [ -z "$CHANNEL" ]; then
    CHANNEL="$(mon channels create --display-name="kind-dev01 alerts" --type=email \
                 --channel-labels="email_address=$ALERT_EMAIL" --format='value(name)')"
    echo ">> канал уведомлений создан: $CHANNEL (адрес — в .local/config.env)"
  else
    echo ">> канал уведомлений уже есть: $CHANNEL"
  fi
else
  echo ">> ALERT_EMAIL не задан: политики без канала (видны в консоли Monitoring), бюджет — письма админам billing" >&2
fi

for f in "$ROOT"/gcp/monitoring/*.json; do
  name="$(jq -r .displayName "$f")"
  if [ -n "$(mon policies list --filter="displayName=\"$name\"" --format='value(name)' | head -1)" ]; then
    echo ">> политика уже есть: $name"; continue
  fi
  out="$TMP/$(basename "$f")"
  if [ -n "$CHANNEL" ]; then
    jq --arg ch "$CHANNEL" '.notificationChannels = [$ch]' "$f" > "$out"
  else
    cp "$f" "$out"
  fi
  mon policies create --policy-from-file="$out" --format='value(name)' >/dev/null
  echo ">> политика создана: $name"
done

# Бюджет. Валюта суммы должна совпадать с валютой billing-аккаунта.
CURRENCY="$(gcloud billing accounts describe "$BILLING_ACCOUNT" --format='value(currencyCode)' 2>/dev/null || true)"
CURRENCY="${CURRENCY:-USD}"
PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')"
if gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" --billing-project="$GCP_PROJECT" \
     --format='value(displayName)' | grep -qxF "$BUDGET_NAME"; then
  echo ">> бюджет уже есть: $BUDGET_NAME"
else
  set -- --billing-account="$BILLING_ACCOUNT" --billing-project="$GCP_PROJECT" \
    --display-name="$BUDGET_NAME" \
    --budget-amount="${BUDGET_AMOUNT}${CURRENCY}" \
    --filter-projects="projects/$PROJECT_NUMBER" \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=1.0 \
    --threshold-rule=percent=1.0,basis=forecasted-spend
  [ -z "$CHANNEL" ] || set -- "$@" --notifications-rule-monitoring-notification-channels="$CHANNEL"
  gcloud billing budgets create "$@" --format='value(name)' >/dev/null
  echo ">> бюджет создан: $BUDGET_NAME, ${BUDGET_AMOUNT} ${CURRENCY}/мес, пороги 50%/100%/прогноз 100%"
fi
rm -rf "$TMP"
echo "Готово. Проверка: Monitoring -> Alerting; Billing -> Budgets & alerts."
