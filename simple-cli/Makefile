.DEFAULT_GOAL := build

CMD_DIR := ./cmd/simple-cli

.PHONY: fmt vet build

fmt:
	go fmt ./...

vet: fmt
	go vet ./...

vet: test
	go test ./...

build: test
	go build $(CMD_DIR)
