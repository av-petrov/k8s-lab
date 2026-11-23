# Архив: e2e-эксперимент с kind (не часть платформы kind-dev01)

Временное место, файлы будут перенесены. Платформа kind-dev01 создаётся из `../../cluster/` (`make cluster-create`).

- `dev01.yaml`, `dev01-with-registry.sh` — исходный kind-конфиг и скрипт с локальным registry (основа для `cluster/create.sh`)
- `go.mod`, `go.sum`, `*_test.go` — e2e-тесты на sigs.k8s.io/e2e-framework (`main_test.go` ссылается на удалённый `dev02.yaml`)
