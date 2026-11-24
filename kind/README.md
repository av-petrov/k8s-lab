# kind-dev01: платформа (Cilium + Hubble + audit + Argo CD, GitOps)

Экспериментальный кластер. Цель — **минимальный ручной bootstrap**: после пересоздания кластера (например, при смене версии)
руками ставятся только CNI, Argo CD и креды, а всё остальное Argo CD берёт из Git (`github.com/av-petrov/k8s-lab`, каталог `kind/`).

Все команды работают только с контекстом `kind-dev01`. Helm хранит кэш, репо и плагины в `./.helm` (в `.gitignore`). `make help` выводит все цели.

## Модель

```
 вручную (make)                          │  Argo CD из Git (argocd/bootstrap/apps/*)
─────────────────────────────────────────┼──────────────────────────────────────────────
 1. cluster-create   kind, без kube-proxy │  root (app-of-apps, ждёт Healthy дочерних)
 2. cilium-install   CNI (helm)           │   ├─ sealed-secrets    wave -20  контроллер (kube-system)
 3. argocd-install   Argo CD (helm)       │   ├─ network-policies  wave -10  kind/policies/
 4. sealed-secrets-key  ключ из GCP SM    │   └─ audit-shipper     wave 0    fluent-bit + values + SealedSecret
 5. argocd-bootstrap project + root app   │   └─ apps (ApplicationSet) wave 11 kind/argocd/list.yaml
                                         │        ├─ podinfo-test   Helm из Helm-репо
                                         │        └─ hello-test     Kustomize из Git
```

Почему Cilium и Argo CD ставятся руками: без CNI не стартует ни один под, включая Argo CD, а Argo CD не может установить сам себя
до того, как появится. Контроллер Sealed Secrets ставится через GitOps: репозиторий публичный, кредов для чтения Git не нужно,
и ни один секрет не требуется до запуска Argo CD. Вручную приносится только **ключ** Sealed Secrets, и он **до** первого старта
контроллера, иначе контроллер сгенерирует свой. `make argocd-bootstrap` без ключа не запустится.
Если репозиторий станет приватным, токен GitHub нельзя будет хранить как SealedSecret (без него Argo CD не прочитает Git):
его надо класть руками через `make argocd-repo-creds` или так же, как ключ, через Secret Manager.

## Bootstrap нового кластера

```bash
cp config.env.example .local/config.env   # один раз: GCP_PROJECT=... (.local/ не в Git)
make cluster-delete            # деструктивно
make cluster-create            # ноды NotReady: CNI ещё нет
make bootstrap                 # = cilium-install + argocd-install
make sealed-secrets-key        # ключ из GCP Secret Manager -> Secret в kube-system (нужен только gcloud login)
make argocd-bootstrap          # проверит ключ -> project + root app -> Argo CD синхронизирует всё остальное
make argocd-apps               # все Application должны быть Synced/Healthy
make policies-validate         # все CNP/CCNP приняты Cilium
make cilium-connectivity       # приёмочный тест (namespace теста исключены из default deny)
```
Носить с собой ничего не нужно, кроме логина в `gcloud`.

## Секреты (Sealed Secrets со своим ключом)

В Git лежат только `*.sealed.yaml` (шифротекст) и публичный `sealed-secrets/sealed-secrets.crt`. Репозиторий публичный:
шифротекст виден всем и навсегда. Если утечёт приватный ключ, менять нужно **сами секреты**, а не только ключ.

При пересоздании кластера пропадают не SealedSecret (они в Git), а приватный ключ контроллера. Поэтому храним ровно его:

| | Где | Как |
|---|---|---|
| Основное | GCP Secret Manager, секрет `sealed-secrets-key` | готовый манифест Secret (kube-system, label `active`). Версии, `version-destroy-ttl` 30 дней (случайный destroy можно отменить), каждое чтение пишется в Cloud Audit Logs |
| Резервная копия | sops-файл (ваш GPG или KMS), хранить **вне** публичного репо | `make sealed-secrets-backup SOPS_BACKUP_FILE=<путь> SOPS_ARGS="--pgp <FPR>"`. Открытые поля metadata, шифруются `data` |

Цена Secret Manager: бесплатно до 6 активных версий и 10 000 обращений в месяц, для нас $0. Проект для ключа лучше выбрать такой,
который не удалится вместе с экспериментом. Удалённый проект ещё 30 дней можно восстановить.

Однократная подготовка (в своём терминале):
```bash
make gcp-setup                 # API Logging + Secret Manager, SA kind-dev01-audit (roles/logging.logWriter)
make sealed-secrets-keygen SOPS_BACKUP_FILE=<путь вне репо> SOPS_ARGS="--pgp <FPR>"
                               # ключ генерируется в памяти -> Secret Manager (+ sops-бэкап); .crt -> sealed-secrets/
make seal-gcp-logging          # ключ SA -> audit/shipper/secrets/gcp-logging-sa.sealed.yaml (открытым нигде не лежит)
git add ... && git commit && git push
```

Новый секрет для любого приложения (офлайн, кластер не нужен):
```bash
kubectl --context kind-dev01 create secret generic <name> -n <ns> --from-literal=KEY=... --dry-run=client -o yaml \
  | make -s seal > <app>/secrets/<name>.sealed.yaml
```
SealedSecret по умолчанию привязан к имени и namespace (scope strict): переименовать его без перезапечатывания нельзя.

Аварии:
- **Пропал или повреждён ключ в Secret Manager:** `make sealed-secrets-restore SOPS_BACKUP_FILE=...` вернёт его и в кластер, и в Secret Manager.
- **Пропали обе копии:** не катастрофа. `FORCE=1 make sealed-secrets-keygen` → перезапечатать все секреты из исходников (`make seal-gcp-logging`, ключи litellm, ...).
- **Ротация ключа:** `FORCE=1 make sealed-secrets-keygen` → `make sealed-secrets-key` (контроллер расшифровывает всеми ключами с label,
  после добавления нужен `kubectl -n kube-system rollout restart deploy/sealed-secrets-controller`) → перезапечатать секреты → push → удалить старый Secret ключа.
- **Ротация ключа SA GCP:** `make seal-gcp-logging` → push → удалить старый ключ в GCP (`gcloud iam service-accounts keys list/delete`).

## Структура

```
cluster/kind-dev01.yaml.tmpl     kind-конфиг: kubeProxyMode: none + audit apiserver (рендерится в .build/)
cluster/create.sh                создание кластера + локальный registry localhost:5001
cluster/gcp-setup.sh, sealed-secrets-keygen.sh, seal-gcp-logging.sh   однократная подготовка GCP и ключей
cluster/gcp-budget.sh, gcp/monitoring/   бюджет GCP и алерты на объём логов (make gcp-budget)
cluster/argocd-repo-creds.sh     только для приватного репо: Secret с GitHub-токеном
sealed-secrets/                  [GitOps] values контроллера + публичный сертификат
config.env.example               шаблон .local/config.env (GCP_PROJECT)
versions.env                     версии того, что ставится руками (kind node, Cilium, Argo CD, helm-diff)
cilium/values.yaml, NOTES.md     Cilium (KPR, Hubble, enforce) и заметки о datapath в kind
policies/                        [GitOps] namespaces + CCNP default deny + CNP argocd / audit-logging / litellm / monitoring
monitoring/prometheus/values.yaml   [GitOps] Prometheus (только server, хранение 24h/1GB): Argo CD + cAdvisor
monitoring/metrics-server/values.yaml   [GitOps] metrics-server (Metrics API: kubectl top, HPA)
audit/audit-policy.yaml          audit policy kube-apiserver (монтируется kind'ом)
audit/shipper/values.yaml        [GitOps] Fluent Bit: audit.log -> GCP Cloud Logging (+ stdout для отладки)
audit/shipper/secrets/           [GitOps] SealedSecret gcp-logging-sa
argocd/values.yaml               Argo CD non-HA
argocd/bootstrap/                AppProject platform, root app, apps/ (дочерние Application)
argocd/bootstrap/apps/30-apps.yaml  [GitOps] AppProject apps + ApplicationSet apps
argocd/list.yaml                 [GitOps] список прикладных приложений (Helm / Kustomize / манифесты)
apps/<name>/                     [GitOps] values (values-<env>.yaml) или kustomize (base/, overlays/<env>/)
*.current-backup.*, audit/kube-apiserver.pod.before.yaml   снимки старого кластера (1.20.3)
archive/e2e/                     временно: старый kind-конфиг и e2e-тесты на Go (не часть платформы)
```

## Версии

- Ставится вручную — `versions.env`: kindest/node v1.35.1, Cilium 1.20.5, argo-cd 10.18.2 (Argo CD v3.6.2), helm-diff v3.12.5.
  (2026-11-23 подняты с 1.20.4 / 10.18.0; в живом кластере до пересоздания — старые, `make diff` покажет разницу.)
- Приложения — `version` в `argocd/list.yaml`: podinfo 6.17.0.
- Под Argo CD — `targetRevision` в `argocd/bootstrap/apps/*.yaml`: sealed-secrets 2.22.0 (контроллер v0.41.2), fluent-bit 0.58.3 (Fluent Bit 5.1.3),
  prometheus 30.0.0 (Prometheus v3.16.0), metrics-server 3.14.0 (v0.9.0) — определено `helm show chart` 2026-11-24.
- Helm-репозиторий Sealed Secrets переехал: `https://bitnami.github.io/sealed-secrets` (старый `bitnami-labs.github.io` отдаёт 404).
- Локальный `kubeseal` v0.27.3 старше контроллера v0.41.2. Офлайн-запечатывание по `--cert` совместимо, но обновить стоит.

Все версии определены через `helm search repo <chart> --versions` 2026-11-15.

## Доступ

| Что | Команда | Адрес |
|---|---|---|
| Hubble UI | `make hubble-ui` | http://localhost:12000 |
| Argo CD | `make argocd-ui` | http://localhost:8081 (порт 8080 на хосте занят `extraPortMappings` kind) |
| Пароль admin Argo CD | `make argocd-password` | выводится только в терминал |
| Audit-логи | GCP Console → Logging → Logs Explorer | `logName="projects/<project>/logs/kube.audit"` |
| Отладка агента | `make audit-shipper-metrics`, `make audit-shipper-logs` | |
| Prometheus | `make prometheus-ui` | http://localhost:9090 |
| Токен read-only Argo CD | `make argocd-observer-token` | выводится только в терминал |

Все сервисы — ClusterIP, без Ingress, NodePort и LoadBalancer.

Порты переопределяются: `make argocd-ui ARGOCD_UI_PORT=18081` (`PROMETHEUS_UI_PORT`, `HUBBLE_UI_PORT`).
Цели `*-ui` перезапускают port-forward сами: kubectl рвёт весь туннель, когда под сбрасывает одно соединение.
У Argo CD (`server.insecure=true`, только http) так происходит от любого TLS-запроса: браузер на
`https://localhost:8081` или `argocd login` без `--skip-test-tls` (CLI сначала шлёт TLS-пробу). Поэтому: в браузере
только `http://`, в CLI всегда `--plaintext --skip-test-tls`.

### Read-only аккаунт Argo CD и Prometheus (для агента argocd-observability)

- Аккаунт `sre-observer` (`apiKey`, без входа в UI) и привязка к `role:readonly` — в `argocd/values.yaml`
  (`configs.cm.accounts.*`, `configs.rbac.policy.csv`). Argo CD ставится helm'ом, поэтому применяется так же:
  `make argocd-diff` → `make argocd-upgrade`. Проверка под токеном (объект приложения — `проект/имя`, поэтому `'*/*'`):
  `argocd account can-i get applications '*/*'` → `yes`, `... sync applications '*/*'` → `no`.
- Токен: `make argocd-ui` (окно), `argocd login localhost:8081 --username admin --plaintext --skip-test-tls`,
  `make argocd-observer-token`.
  Токен — секрет, в Git не кладётся (в `.env` агента). Сервер хранит его id в `argocd-secret`, `make argocd-upgrade` его не затирает.
  Отозвать: `argocd account delete-token --account sre-observer <id>`.
- Prometheus — Application `prometheus` (`argocd/bootstrap/apps/40-prometheus.yaml`, проект `platform`, namespace `monitoring`):
  только server, scrape 30s, хранение 24h и не более 1 GB (PVC 2Gi), цели — Argo CD (8082/8083/8084) и cAdvisor kubelet
  (CPU/память контейнеров). Сеть: `policies/40-monitoring.yaml` + `argocd-metrics-from-prometheus` в `policies/10-argocd.yaml`.
- metrics-server — Application `metrics-server` (`argocd/bootstrap/apps/41-metrics-server.yaml`, namespace `kube-system`):
  Metrics API для `kubectl top` и HPA, только последний срез в памяти. В kind нужен `--kubelet-insecure-tls`
  (сертификаты kubelet самоподписанные). kube-system вне baseline default deny, CNP не нужны.
- AppProject `platform` (`argocd/bootstrap/project.yaml`) не под Argo CD: после правки (репозитории prometheus-community
  и metrics-server, destination `monitoring`, кластерный kind `APIService`) применить `make argocd-bootstrap`,
  иначе новые Application будут InvalidSpecError / ComparisonError.

### Пароль admin Argo CD

| Secret (`argocd`) | Что внутри |
|---|---|
| `argocd-initial-admin-secret` | начальный пароль **открытым текстом** (base64). После смены пароля недействителен — удалить |
| `argocd-secret` | `admin.password` — **bcrypt-хэш** текущего пароля, `admin.passwordMtime`. Пишет argocd-server |

После первого входа смените пароль и удалите начальный секрет:
```bash
make argocd-ui                                             # отдельное окно: port-forward localhost:8081
argocd login localhost:8081 --username admin --plaintext --skip-test-tls   # server.insecure=true; без TLS-пробы
argocd account update-password
kubectl --context kind-dev01 -n argocd delete secret argocd-initial-admin-secret
```

- Хэш живёт только в кластере: после пересоздания снова случайный пароль в `argocd-initial-admin-secret`.
  Постоянный пароль — bcrypt-хэш в `configs.secret.argocdServerAdminPassword` (не в Git открыто: через Secret Manager,
  как ключ Sealed Secrets) или SSO (dex) с отключённым локальным admin.
- `make argocd-upgrade` пароль не затирает: `admin.password` добавлен сервером, а не чартом, Helm (three-way merge) его сохраняет.
- Забыли пароль: удалить `admin.password` и `admin.passwordMtime` из `argocd-secret`, затем
  `kubectl --context kind-dev01 -n argocd rollout restart deploy/argocd-server` — сервер создаст новый `argocd-initial-admin-secret`.

Примеры запросов в Logs Explorer:
```
logName:"kube.audit" AND jsonPayload.verb="delete"
logName:"kube.audit" AND jsonPayload.objectRef.resource="secrets" AND NOT jsonPayload.user.username:"system:"
logName:"kube.audit" AND jsonPayload.objectRef.apiGroup="rbac.authorization.k8s.io"
```

## Приложения (ApplicationSet + list.yaml)

Прикладные приложения не требуют своих Application-файлов: достаточно записи в `argocd/list.yaml` и push в `main`.
ApplicationSet `apps` (`argocd/bootstrap/apps/30-apps.yaml`) делает из каждой записи Application `<name>-<environment>`
в AppProject `apps`. Схема полей — в шапке `list.yaml`. Кратко:

| Тип | Что задать | Откуда манифесты |
|---|---|---|
| Helm из Helm-репозитория | `repoURL`, `chart`, `version` | values: `apps/<name>/values-<env>.yaml` (или `valuesFile`), нет файла — дефолты чарта |
| Kustomize | ничего (или `manifestsPath`) | `apps/<name>/overlays/<env>/kustomization.yaml` |
| Helm-чарт в Git | `manifestsPath` на каталог с `Chart.yaml` | Argo CD определит сам |
| Обычные YAML | `manifestsPath` на каталог | Argo CD определит сам |

Флаги `autoSync` / `prune` / `createNamespace` — строки `"true"`/`"false"`. `prune` работает только при `autoSync: "true"`.
При `autoSync: "false"` синк — из UI или `argocd app sync <name>-<env>`.

Добавить Helm-приложение:
1. `make repos` / `helm repo add` → `helm search repo <repo>/<chart> --versions` → версию в `version` (не по памяти).
2. URL Helm-репозитория — в `sourceRepos` AppProject `apps` (`30-apps.yaml`), иначе Application будет `InvalidSpec`.
3. Если чарт содержит кластерные ресурсы (CRD, ClusterRole, Webhook) — AppProject `apps` их не пропустит
   (`clusterResourceWhitelist` = только Namespace). Расширять осознанно или вести такое приложение в проекте `platform`.
4. Связи приложения — CiliumNetworkPolicy (в namespace приложений действует default deny: разрешены только DNS и пробы kubelet).
   Для Kustomize — рядом с манифестами, для Helm из репо — в `policies/`.
5. commit + push → `make argocd-apps`.

Ограничения AppProject `apps`: запрещены namespace `kube-*`, `argocd`, `audit-logging`, `cilium-*`, `local-path-storage`.
Удаление записи из `list.yaml` удаляет Application, но ресурсы остаются (`preserveResourcesOnDeletion: true`): защита от того,
что битый `list.yaml` снесёт все приложения сразу. Ресурсы потом удалить руками.
Проверить шаблон без кластера можно через `helm template` (тот же Go template + sprig): так он проверялся при написании.

## Сетевые политики (enforce)

- `00-baseline-default-deny` (CCNP): default deny на ingress и egress для всех namespace, кроме
  `kube-system`, `kube-public`, `kube-node-lease`, `local-path-storage`, `cilium-secrets`, `cilium-test-1`, `cilium-test-ccnp1/2`.
  Разрешено DNS к kube-dns через L7 DNS-прокси (запросы видны в Hubble, работает `toFQDNs`) и ingress от `host` (пробы kubelet).
  В селекторе обязателен `Exists` по `io.kubernetes.pod.namespace`: один `NotIn` совпадает и с endpoint без метки namespace
  (`reserved:health`). В audit mode это показало `remote-node -> health AUDITED`, в enforce сломало бы health-check Cilium.
- `10-argocd`: доступ к kube-apiserver только у server, application-controller, applicationset, notifications и redis-secret-init.
  repo-server и notifications ходят на world:443 (repo-server ещё на :22). Внутренние связи: → repo-server:8081, → redis:6379.
  NetworkPolicy чарта выключена, источник правды один — Cilium.
  TODO: сузить egress repo-server до `toFQDNs` по DNS, который он реально запрашивает
  (`hubble observe -n argocd --protocol dns`: github.com, *.github.io, release-assets/objects.githubusercontent.com, ...).
- `20-audit-logging`: Fluent Bit → только `logging.googleapis.com` и `oauth2.googleapis.com`:443.
- `30-litellm`: litellm → 0.0.0.0/0 (временно), litellm ↔ postgres:5432, API :4000 из любого namespace.
- **Каждому новому приложению нужна политика**, иначе под default deny у него будет только DNS. Политику удобно класть в тот же Application.
- Ожидаемый шум в `make hubble-dropped`: ICMPv6 `Unsupported L3 protocol` (IPv6 в Cilium выключен, а у veth нод kind есть link-local).
- Запросы `kubectl get --raw .../pods/<pod>:port/proxy` и `.../services/.../proxy` к подам на worker-нодах дропаются:
  apiserver для них — `remote-node`. `port-forward` и `exec` работают: они идут через kubelet в netns пода.
- Отладка новой политики: временно `policyAuditMode: true` → `make cilium-upgrade` → `make hubble-audit`.
- После изменения политик: `make policies-validate`. Невалидную политику (например, пустой `egress: []`) Cilium отклоняет, а dry-run и Argo CD показывают успех.

### Break-glass

Политики синхронизирует Argo CD с `selfHeal`, поэтому простой `kubectl delete` откатится обратно. Если политика отрезала что-то критичное
(в худшем случае сам Argo CD от Git):
```bash
make break-glass-policies   # снимает автосинк с root и network-policies, удаляет baseline default deny
# починить политику в Git -> push -> make argocd-bootstrap (вернёт автосинк root, а root — дочерним)
```

## Audit-логи

Включены через kind-конфиг: `kubeadmConfigPatches` (extraArgs и extraVolumes apiserver) + `extraMounts` файла `audit/audit-policy.yaml`.
Лог пишется в `/var/log/kubernetes/audit/audit.log` на control-plane, ротация 100 МБ × 5 файлов, 7 дней.
Apiserver читает политику только при старте. После её правки нужен рестарт apiserver или пересоздание кластера.

Kind-патч kubeadm: kind v0.31 генерирует конфиг в `kubeadm.k8s.io/v1beta3` (kubeadm потом сам конвертирует в v1beta4), поэтому в
`kubeadmConfigPatches` нужен `extraArgs` в виде map и без `apiVersion`. Patch с `apiVersion: v1beta4` kind молча пропускает.
Отладка: `KIND_FLAGS="-v 6" make cluster-create`.

Доставка: file backend + Fluent Bit DaemonSet только на control-plane. Агент читает hostPath read-only, хранит offset и файловый буфер
в hostPath `/var/lib/fluent-bit-audit`. Если GCP недоступен, события копятся на диске и досылаются (`Retry_Limit no_limits`).

Почему не webhook backend (`--audit-webhook-config-file`):
- webhook шлёт события прямо из apiserver. В режиме batch при недоступном приёмнике буфер в памяти apiserver переполняется и события теряются,
  а в режиме blocking тормозят сами запросы к API;
- конфиг и креды приёмника становятся частью static pod. Любая смена приёмника — рестарт apiserver;
- file + агент: запас на диске, буфер и ретраи в агенте, приёмник меняется через Git без рестарта apiserver.

**Стоимость (GCP Cloud Logging):** объём после фильтрации audit-политикой — около 6 КБ/мин в простое (~0,3 ГБ/мес),
с активной работой 1–3 ГБ/мес. Бесплатный лимит — 50 ГиБ/мес на проект, хранение 30 дней в `_Default` бесплатно. Итог ≈ $0.
Рекомендуется budget alert в проекте (например, $1). Долгий архив при необходимости делается log sink'ом в GCS (класс Archive), агент менять не нужно.
Ротация ключа SA — см. раздел «Секреты». Отказ от эксперимента: удалить SA `kind-dev01-audit` и секрет `sealed-secrets-key`.
Пока SealedSecret `gcp-logging-sa` не создан, под Fluent Bit висит в `ContainerCreating`, и это ожидаемо.

## Бюджет GCP (бесплатный лимит логов)

Cloud Logging: **50 GiB на проект в месяц бесплатно**, сверх — $0.50/GiB (включает 30 дней хранения); хранение дольше
30 дней — $0.01/GiB/мес; запросы бесплатны. Источник: https://cloud.google.com/products/observability/pricing
Замер 2026-11-23: в обычном режиме ~0.6 GiB/мес (~1% лимита), пересоздание кластера (bootstrap) — ~10 MB.
Основной объём — Argo CD (`update applicationsets`, `patch applications`) и ручной `kubectl`.

Жёсткого лимита на приём логов в GCP нет, бюджет только оповещает. Поэтому слои:

| Слой | Что | Как |
|---|---|---|
| Алерт по объёму | `logging.googleapis.com/billing/monthly_bytes_ingested` > 25 GiB (WARNING) и > 40 GiB (CRITICAL) | `make gcp-budget`, `gcp/monitoring/*.json` |
| Бюджет | сумма `BUDGET_AMOUNT` (по умолчанию 1 в валюте billing-аккаунта), пороги 50% / 100% / прогноз 100% | `make gcp-budget` |
| Аварийный выключатель | исключение `drop-kube-audit` на sink `_Default`: логи не принимаются и не тарифицируются (теряются; stdout агента остаётся) | `make gcp-logging-off` / `make gcp-logging-on` |

Алерт по объёму срабатывает раньше бюджета: пока объём в бесплатном лимите, бюджет видит $0.
Настройка (один раз, в своём терминале, нужны права на billing-аккаунт):
```bash
# в .local/config.env (не в Git), пример — config.env.example:
#   BILLING_ACCOUNT=$(gcloud billing projects describe $GCP_PROJECT --format='value(billingAccountName)')
#   ALERT_EMAIL=...        (пусто — алерты только в консоли, письма бюджета — админам billing)
make gcp-budget
```
Скрипт идемпотентен: существующие канал, политики и бюджет не меняет. Изменить — удалить в консоли и запустить снова.
Если объём растёт: сначала `audit/audit-policy.yaml` (шумные пользователи/ресурсы → `None`), затем фильтр `throttle` в Fluent Bit.

## Upgrade

- **Cilium и Argo CD** (helm, руками): поменять версию в `versions.env` → прочитать changelog и breaking changes → `make <cilium|argocd>-diff` → `make <cilium|argocd>-upgrade`.
  Для минорного апгрейда Cilium рекомендуется `cilium-preflight` (официальный upgrade guide).
  `rollOutCiliumPods: true`: смена `cilium-config` сама перезапускает агентов (rolling, `maxUnavailable: 2`; на время рестарта агента на ноде DNS через прокси может давать таймауты в несколько секунд).
- **Компоненты под Argo CD:** поменять `targetRevision` или values в Git → PR/commit → Argo CD синхронизирует. Diff виден в UI или через `argocd app diff`.
- **Kubernetes:** поменять `KIND_NODE_IMAGE` → bootstrap нового кластера по инструкции выше. В этом и состоит эксперимент.

## Rollback

- Helm (Cilium, Argo CD): `helm --kube-context kind-dev01 -n <ns> history <release>` → `helm ... rollback <release> <rev>`.
- GitOps-компоненты: `git revert` → push. Аварийно — History and Rollback в UI (автосинк при этом надо снять).
- Политики: см. Break-glass.

## Дальше

1. Сузить egress repo-server (`toFQDNs` по наблюдаемому DNS).
2. litellm как Application: чарт, values без секретов в Git, ключи — в Secret, сделанном руками (или External Secrets).
3. Argo CD self-management: Application на чарт argo-cd с `argocd/values.yaml`, без prune. Ошибка в values может сломать Argo CD,
   тогда чинить через `make argocd-upgrade` руками. После этого `make argocd-upgrade` использовать только для bootstrap.
   `argocd-secret` меняет и сам сервер (`admin.password`, `server.secretkey`): до включения selfHeal добавить
   `ignoreDifferences` на его `/data` или `configs.secret.createSecret: false` (Secret создаётся вне чарта), иначе
   Argo CD и argocd-server будут перезаписывать друг друга.
4. Cilium под Argo CD — последним и осторожно (CD-система, которая сама зависит от CNI):
   - `prune: false` и без `selfHeal` на старте, ручной sync;
   - TLS-секреты Hubble и `cilium-ca` перегенерируются при каждом рендере (`hubble.tls.auto.method: helm`): либо `ignoreDifferences`, либо `cronJob`/cert-manager;
   - самая ранняя sync wave (-100), `argocd.argoproj.io/sync-options: Delete=false` на ресурсы;
   - bootstrap всё равно начинается с `make cilium-install`. Argo CD потом «усыновляет» релиз с теми же values.
5. Если секретов станет много: External Secrets Operator с GCP Secret Manager в качестве бэкенда (тот же Secret Manager, без запечатывания).

## Известные ограничения kind

- Ноды — контейнеры на общем ядре VM. XDP и DSR не используются. LoadBalancer IP с macOS-хоста недоступны.
- При пересоздании кластера обязателен `kubeProxyMode: none` (уже в `cluster/kind-dev01.yaml.tmpl`).
- `kind create` переключает current-context. `cluster/create.sh` восстанавливает предыдущий.
- `cilium connectivity test` корректен только при `policyAuditMode: false`. Под audit mode ~47 тестов падают с «succeeded while it should have failed».
- `~/.kube/config` доступен группе и всем (helm предупреждает): `chmod 600 ~/.kube/config`.
- Сервер 1.35, kubectl 1.33 — разница больше поддерживаемой, лучше обновить kubectl.
- Старые `dev01.yaml`, `dev01-with-registry.sh` и e2e-тесты на Go перенесены в `archive/e2e/` (временно). Новый кластер создаётся из `cluster/`.

## helm-diff

Плагин стоит локально в `./.helm/data`. Последняя совместимая с Helm v3.16.3 версия — v3.12.5: начиная с v3.13 у плагина
`platformHooks`, а Helm 3.16 их не понимает. После обновления Helm переустановить свежую:
`HELM_DATA_HOME=$PWD/.helm/data HELM_CONFIG_HOME=$PWD/.helm/config helm plugin install https://github.com/databus23/helm-diff --version <tag>`.
Без плагина `make *-diff` сам переключается на `helm template | kubectl diff`.
В `make cilium-diff` всегда «изменены» `cilium-ca` и TLS-секреты Hubble: они генерируются при каждом рендере.
