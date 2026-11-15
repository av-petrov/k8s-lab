# Платформа kind-dev01. Все команды работают только с контекстом kind-dev01.
include versions.env
# Личные настройки (GCP_PROJECT=...), не в Git: .local/ игнорируется. Пример — config.env.example.
-include .local/config.env
export GCP_PROJECT

CTX            := kind-dev01
KUBECTL        := kubectl --context $(CTX)
HELM           := helm --kube-context $(CTX)
CILIUM         := cilium --context $(CTX)
export HELM_CACHE_HOME  := $(CURDIR)/.helm/cache
export HELM_CONFIG_HOME := $(CURDIR)/.helm/config
export HELM_DATA_HOME   := $(CURDIR)/.helm/data

# helm diff, если плагин установлен; иначе helm template | kubectl diff (server-side).
HAS_HELM_DIFF := $(shell HELM_DATA_HOME=$(CURDIR)/.helm/data HELM_CONFIG_HOME=$(CURDIR)/.helm/config helm plugin list 2>/dev/null | grep -q '^diff' && echo yes)

# $(call helm_diff,release,namespace,chart,version,values)
define helm_diff
	@if [ "$(HAS_HELM_DIFF)" = yes ]; then \
	  $(HELM) diff upgrade $(1) $(3) -n $(2) --version $(4) -f $(5) --allow-unreleased; \
	else \
	  echo ">> helm-diff не установлен: helm template | kubectl diff"; \
	  $(HELM) template $(1) $(3) -n $(2) --version $(4) -f $(5) --include-crds \
	    | $(KUBECTL) diff -n $(2) --server-side --force-conflicts -f - ; test $$? -le 1; \
	fi
endef

.PHONY: help repos cluster-create cluster-delete \
        cilium-install cilium-upgrade cilium-diff cilium-status cilium-kpr cilium-connectivity \
        hubble-ui hubble-audit hubble-dropped \
        policies-diff policies-validate break-glass-policies \
        gcp-setup sealed-secrets-keygen sealed-secrets-key sealed-secrets-backup sealed-secrets-restore seal-gcp-logging seal audit-shipper-logs audit-shipper-metrics \
        argocd-install argocd-upgrade argocd-diff argocd-ui argocd-password \
        argocd-repo-creds argocd-bootstrap argocd-apps bootstrap diff

help: ## список целей
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  %-24s %s\n",$$1,$$2}'

repos: ## добавить/обновить helm-репозитории (в ./.helm)
	helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
	helm repo update

# --- кластер (деструктивно!) --------------------------------------------
cluster-create: ## создать kind-кластер dev01 (без kube-proxy, с audit)
	./cluster/create.sh

cluster-delete: ## УДАЛИТЬ kind-кластер dev01
	kind delete cluster --name dev01

# --- Cilium ------------------------------------------------------------
cilium-install: repos ## установить Cilium (первичная установка)
	$(HELM) upgrade --install cilium cilium/cilium -n kube-system --version $(CILIUM_CHART_VERSION) -f cilium/values.yaml --wait --timeout 10m
	$(CILIUM) status --wait

cilium-upgrade: cilium-install ## обновить Cilium (helm upgrade с values.yaml)

cilium-diff: ## diff Cilium: живое состояние против values.yaml
	$(call helm_diff,cilium,kube-system,cilium/cilium,$(CILIUM_CHART_VERSION),cilium/values.yaml)

cilium-status: ## статус Cilium
	$(CILIUM) status --wait

cilium-kpr: ## детали KubeProxyReplacement
	$(KUBECTL) -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | sed -n '/KubeProxyReplacement Details/,/^BPF Maps/p'
	$(KUBECTL) -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'Routing|Masquerading|KubeProxy'

cilium-connectivity: ## cilium connectivity test (корректен только при policyAuditMode=false), потом удалить ns
	$(CILIUM) connectivity test --test-namespace cilium-test ; rc=$$?; \
	  $(KUBECTL) delete ns cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2 --ignore-not-found --wait=false; exit $$rc

hubble-ui: ## Hubble UI -> http://localhost:12000
	$(KUBECTL) -n kube-system port-forward svc/hubble-ui 12000:80

hubble-audit: ## потоки, которые в enforce были бы дропнуты
	$(KUBECTL) -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict AUDIT --last 200

hubble-dropped: ## реально дропнутые потоки
	$(KUBECTL) -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED --last 200

# --- политики (под управлением Argo CD: Application network-policies) ----
policies-diff: ## diff политик: Git-рабочая копия против кластера
	$(KUBECTL) diff -f policies/ ; test $$? -le 1

policies-validate: ## статус Valid у всех CNP/CCNP (dry-run и Argo CD невалидную политику не ловят)
	@$(KUBECTL) get cnp,ccnp -A -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name} {range .status.conditions[?(@.type=="Valid")]}{.status} {.message}{end}{"\n"}{end}' \
	  | tee /dev/stderr | awk '$$2!="True"{bad=1} END{exit bad}'

break-glass-policies: ## АВАРИЯ: выключить автосинк root/network-policies и удалить baseline default deny
	$(KUBECTL) -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
	$(KUBECTL) -n argocd patch application network-policies --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
	$(KUBECTL) delete ccnp baseline-default-deny --ignore-not-found
	@echo ">> default deny снят. Починить политику в Git, затем: make argocd-bootstrap (вернёт автосинк)"

# --- audit (Fluent Bit под управлением Argo CD: Application audit-shipper)
audit-shipper-logs: ## события audit, которые отправил агент (дубль stdout)
	$(KUBECTL) -n audit-logging logs ds/audit-shipper-fluent-bit --tail=20

audit-shipper-metrics: ## счётчики Fluent Bit (записи, ошибки и ретраи по выходам)
	@P=$$($(KUBECTL) -n audit-logging get pod -l app.kubernetes.io/name=fluent-bit -o jsonpath='{.items[0].metadata.name}'); \
	  $(KUBECTL) get --raw "/api/v1/namespaces/audit-logging/pods/$$P:2020/proxy/api/v1/metrics"; echo

# --- Argo CD -------------------------------------------------------------
argocd-install: repos ## установить Argo CD (non-HA)
	$(HELM) upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version $(ARGOCD_CHART_VERSION) -f argocd/values.yaml --wait --timeout 10m

argocd-upgrade: argocd-install ## обновить Argo CD

argocd-diff: ## diff Argo CD
	$(call helm_diff,argocd,argocd,argo/argo-cd,$(ARGOCD_CHART_VERSION),argocd/values.yaml)

argocd-ui: ## Argo CD UI -> http://localhost:8081 (8080 на хосте занят kind)
	$(KUBECTL) -n argocd port-forward svc/argocd-server 8081:80

argocd-password: ## показать начальный пароль admin (только в терминал)
	@$(KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# --- секреты (Sealed Secrets, свой ключ) — запускать в СВОЁМ терминале ---------
gcp-setup: ## однократно: API Logging/Secret Manager + SA kind-dev01-audit (нужен GCP_PROJECT)
	./cluster/gcp-setup.sh

sealed-secrets-keygen: ## однократно/ротация: пара ключей -> Secret Manager (+ sops-бэкап, если SOPS_BACKUP_FILE)
	./cluster/sealed-secrets-keygen.sh

sealed-secrets-key: ## bootstrap: ключ из Secret Manager -> Secret в kube-system (до старта контроллера)
	@gcloud secrets versions access latest --secret sealed-secrets-key --project "$(GCP_PROJECT)" | $(KUBECTL) apply -f -

sealed-secrets-backup: ## резервная копия ключа из Secret Manager в sops-файл (SOPS_BACKUP_FILE, SOPS_ARGS)
	@test -n "$(SOPS_BACKUP_FILE)" || { echo "задайте SOPS_BACKUP_FILE=..."; exit 1; }
	@bash -o pipefail -c 'gcloud secrets versions access latest --secret sealed-secrets-key --project "$(GCP_PROJECT)" \
	  | sops --encrypt $(SOPS_ARGS) --encrypted-regex "^(data|stringData)$$" --input-type yaml --output-type yaml /dev/stdin > "$(SOPS_BACKUP_FILE)"'
	@echo "backup: $(SOPS_BACKUP_FILE)"

sealed-secrets-restore: ## авария: ключ из sops-бэкапа -> кластер и обратно в Secret Manager
	@test -n "$(SOPS_BACKUP_FILE)" || { echo "задайте SOPS_BACKUP_FILE=..."; exit 1; }
	sops --decrypt "$(SOPS_BACKUP_FILE)" | $(KUBECTL) apply -f -
	sops --decrypt "$(SOPS_BACKUP_FILE)" | gcloud secrets versions add sealed-secrets-key --project "$(GCP_PROJECT)" --data-file=- >/dev/null

seal-gcp-logging: ## новый ключ SA GCP -> SealedSecret audit/shipper/secrets/gcp-logging-sa.sealed.yaml
	./cluster/seal-gcp-logging.sh

seal: ## запечатать Secret из stdin: kubectl create secret ... --dry-run=client -o yaml | make -s seal > x.sealed.yaml
	@kubeseal --cert sealed-secrets/sealed-secrets.crt --format yaml

argocd-repo-creds: ## ТОЛЬКО для приватного репо: Secret с GitHub-токеном (интерактивно)
	./cluster/argocd-repo-creds.sh

argocd-bootstrap: ## AppProject + root Application: дальше всё ставит Argo CD из Git
	@$(KUBECTL) -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o name | grep -q . \
	  || { echo ">> нет ключа Sealed Secrets в kube-system: сначала make sealed-secrets-key"; exit 1; }
	$(KUBECTL) apply -f argocd/bootstrap/project.yaml -f argocd/bootstrap/root-app.yaml

argocd-apps: ## статус всех Application
	$(KUBECTL) -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision

# Минимальный ручной bootstrap нового кластера: helm (Cilium, Argo CD) + ключ Sealed Secrets.
bootstrap: cilium-install argocd-install ## Cilium + Argo CD; затем креды и make argocd-bootstrap
	@echo ">> дальше: make sealed-secrets-key && make argocd-bootstrap"

diff: cilium-diff argocd-diff policies-diff ## diff компонентов, которые ставятся вручную через helm
