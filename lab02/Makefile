.PHONY: build test race lint up down clean provider-mode stats

build:
	go build ./...

test:
	go test ./...

race:
	go test -race ./...

lint:
	golangci-lint run ./...

up:
	docker compose up --build -d

down:
	docker compose down -v

clean:
	go clean -testcache

# Переключить поведение поставщика: make provider-mode MODE='{"latency_ms":2000}'
provider-mode:
	curl -s -X POST localhost:9090/admin/mode -H 'Content-Type: application/json' -d '$(MODE)'

# Сколько обращений принял поставщик и какова была пиковая одновременность
stats:
	@curl -s localhost:9090/admin/stats; echo
