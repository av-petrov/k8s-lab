#!/bin/sh
# Создаёт в argocd Secret с кредами GitHub для Argo CD (repository-секрет).
# Токен НЕ пишется ни в файлы, ни в аргументы команд: берётся из $GITHUB_TOKEN или вводится скрыто.
# Нужен fine-grained PAT: только репозиторий k8s-lab, Permissions -> Contents: Read-only.
# Запускать в своём терминале: make argocd-repo-creds
set -o errexit -o nounset
CTX=kind-dev01
REPO_URL="${REPO_URL:-https://github.com/av-petrov/k8s-lab.git}"
if [ -z "${GITHUB_TOKEN:-}" ]; then
  printf 'GitHub token для %s (ввод скрыт): ' "$REPO_URL"
  stty -echo; read -r GITHUB_TOKEN; stty echo; echo
fi
[ -n "$GITHUB_TOKEN" ] || { echo "пустой токен" >&2; exit 1; }
kubectl --context "$CTX" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: repo-k8s-lab
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${REPO_URL}
  username: x-access-token
  password: ${GITHUB_TOKEN}
YAML
echo "Готово. Проверка: kubectl --context $CTX -n argocd get secret repo-k8s-lab"
