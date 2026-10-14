#!/usr/bin/env bash
#
# Каркас практики 02 (02-weather).
# Сгенерирован tools/pack-lab.sh — вручную не править.
#
# Развернуть каркас:      ./lab02-init.sh
# Сверить с текущей:      ./lab02-init.sh --check
#
set -euo pipefail

LAB_DIR="${LAB_DIR:-lab02}"
STARTER_VERSION="c9ad4ad4fdb5"
PACKED_AT="2026-09-18"

FILES=(
  ".golangci.yml"
  "Dockerfile"
  "Dockerfile.provider"
  "Makefile"
  "cmd/provider/main.go"
  "cmd/weather/main.go"
  "docker-compose.yml"
  "go.mod"
  "internal/config/config.go"
  "internal/provider/provider.go"
  "internal/weatherapi/api.go"
)

INFRA=(
  "go.mod"
  "Makefile"
  "Dockerfile"
  "Dockerfile.provider"
  "docker-compose.yml"
  ".golangci.yml"
  "cmd/provider/main.go"
  "internal/provider/provider.go"
)

emit() {
  case "$1" in
  ".golangci.yml")
    cat <<'__LAB_FILE_EOF__'
version: "2"

linters:
  enable:
    - errcheck
    - govet
    - ineffassign
    - staticcheck
    - unused
    - bodyclose
    - errorlint
    - noctx
    - contextcheck

  exclusions:
    rules:
      # httptest.NewRequest не уходит в сеть, и требовать для него контекст
      # незачем: правило noctx нацелено на запросы без дедлайна.
      - path: _test\.go
        linters:
          - noctx

formatters:
  enable:
    - gofmt
    - goimports
__LAB_FILE_EOF__
    ;;
  "Dockerfile")
    cat <<'__LAB_FILE_EOF__'
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/weather ./cmd/weather

FROM alpine:3.21
COPY --from=build /out/weather /weather
EXPOSE 8080
ENTRYPOINT ["/weather"]
__LAB_FILE_EOF__
    ;;
  "Dockerfile.provider")
    cat <<'__LAB_FILE_EOF__'
# Поставщик — часть каркаса. Собирается отдельным образом, чтобы его можно
# было перезапускать, не трогая сервис.
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/provider ./cmd/provider

FROM alpine:3.21
COPY --from=build /out/provider /provider
EXPOSE 9090
ENTRYPOINT ["/provider"]
__LAB_FILE_EOF__
    ;;
  "Makefile")
    cat <<'__LAB_FILE_EOF__'
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
__LAB_FILE_EOF__
    ;;
  "cmd/provider/main.go")
    cat <<'__LAB_FILE_EOF__'
// Команда provider — поставщик погоды с управляемыми возмущениями.
//
// Это часть каркаса, а не работа студента. Поставщик умеет отвечать медленно,
// отвечать ошибкой и не отвечать вовсе; режим переключается на ходу.
// Он же считает обращения — по этому счётчику проверяется, что повторы
// не превращаются в шторм.
package main

import (
	"encoding/json"
	"hash/fnv"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"sync"
	"time"
)

type mode struct {
	LatencyMS int     `json:"latency_ms"` // задержка перед ответом
	ErrorRate float64 `json:"error_rate"` // доля ответов 500, от 0 до 1
	Down      bool    `json:"down"`       // не отвечать вовсе
}

type stats struct {
	Requests    int64     `json:"requests"`      // сколько обращений принято
	InFlightMax int64     `json:"in_flight_max"` // пиковая одновременность
	Since       time.Time `json:"since"`
}

type server struct {
	mu       sync.Mutex
	mode     mode
	st       stats
	inFlight int64
}

func (s *server) forecast(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	m := s.mode
	s.st.Requests++
	s.inFlight++
	if s.inFlight > s.st.InFlightMax {
		s.st.InFlightMax = s.inFlight
	}
	s.mu.Unlock()

	defer func() {
		s.mu.Lock()
		s.inFlight--
		s.mu.Unlock()
	}()

	city := r.URL.Query().Get("city")
	if city == "" {
		http.Error(w, `{"error":"city is required"}`, http.StatusBadRequest)
		return
	}

	if m.Down {
		// Не отвечаем и держим соединение: так выглядит зависший поставщик.
		<-r.Context().Done()
		return
	}
	if m.LatencyMS > 0 {
		select {
		case <-time.After(time.Duration(m.LatencyMS) * time.Millisecond):
		case <-r.Context().Done():
			return
		}
	}
	if m.ErrorRate > 0 && rand.Float64() < m.ErrorRate {
		http.Error(w, `{"error":"upstream is having a bad day"}`, http.StatusInternalServerError)
		return
	}
	if city == "Атлантида" {
		http.Error(w, `{"error":"city not found"}`, http.StatusNotFound)
		return
	}

	// Температура выводится из имени города: одинаковый город — одинаковый ответ.
	h := fnv.New32a()
	_, _ = h.Write([]byte(city))
	temp := float64(int(h.Sum32()%450))/10 - 20

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"city": city, "temp_c": temp})
}

func (s *server) adminMode(w http.ResponseWriter, r *http.Request) {
	var m mode
	if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
		http.Error(w, `{"error":"bad mode"}`, http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	s.mode = m
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) adminStats(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	st := s.st
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(st)
}

func (s *server) adminReset(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.st = stats{Since: time.Now()}
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	addr := os.Getenv("HTTP_ADDR")
	if addr == "" {
		addr = ":9090"
	}

	s := &server{st: stats{Since: time.Now()}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /forecast", s.forecast)
	mux.HandleFunc("POST /admin/mode", s.adminMode)
	mux.HandleFunc("GET /admin/stats", s.adminStats)
	mux.HandleFunc("POST /admin/reset", s.adminReset)

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("поставщик слушает %s", addr)
	log.Fatal(srv.ListenAndServe())
}
__LAB_FILE_EOF__
    ;;
  "cmd/weather/main.go")
    cat <<'__LAB_FILE_EOF__'
// Команда weather — сервис сводки погоды.
package main

// TODO: прочитать конфигурацию, собрать клиента поставщика и кэш,
// поднять HTTP-сервер с таймаутами.
func main() {
	panic("не реализовано")
}
__LAB_FILE_EOF__
    ;;
  "docker-compose.yml")
    cat <<'__LAB_FILE_EOF__'
services:
  provider:
    build:
      context: .
      dockerfile: Dockerfile.provider
    environment:
      HTTP_ADDR: ":9090"
    ports:
      - "9090:9090"
    stop_grace_period: 2s

  weather:
    build: .
    depends_on:
      - provider
    environment:
      HTTP_ADDR: ":8080"
      PROVIDER_URL: "http://provider:9090"
      REQUEST_BUDGET: "2s"
      PROVIDER_TIMEOUT: "300ms"
      RETRY_MAX: "2"
      PROVIDER_CONCURRENCY: "8"
      BREAKER_FAILURES: "5"
      BREAKER_COOLDOWN: "3s"
      CACHE_TTL: "60s"
      LOG_LEVEL: "info"
    ports:
      - "8080:8080"
    stop_grace_period: 2s
__LAB_FILE_EOF__
    ;;
  "go.mod")
    cat <<'__LAB_FILE_EOF__'
module weather

go 1.27
__LAB_FILE_EOF__
    ;;
  "internal/config/config.go")
    cat <<'__LAB_FILE_EOF__'
// Package config читает конфигурацию сервиса из переменных окружения.
package config

// TODO: разобрать переменные окружения из задания, проверить значения
// и вернуть ошибку, если они бессмысленны. Сервис с некорректной
// конфигурацией стартовать не должен.
__LAB_FILE_EOF__
    ;;
  "internal/provider/provider.go")
    cat <<'__LAB_FILE_EOF__'
// Package provider — клиент внешнего поставщика погоды.
//
// Тип Forecast, ошибки и сигнатура New() — часть контракта практики.
// Менять их нельзя: против них написаны проверки курса.
package provider

import (
	"context"
	"errors"
	"time"
)

// Forecast — то, что поставщик умеет рассказать о городе.
type Forecast struct {
	City  string  `json:"city"`
	TempC float64 `json:"temp_c"`
}

// ErrUnavailable возвращается, когда поставщика не удалось опросить:
// он не ответил, ответил ошибкой или обращение к нему не состоялось вовсе.
var ErrUnavailable = errors.New("provider unavailable")

// ErrNotFound возвращается, когда поставщик ответил, что города не знает.
// Такой отказ окончателен: повторять его бессмысленно.
var ErrNotFound = errors.New("city not found")

// Client опрашивает поставщика.
//
// Forecast обязан уложиться в срок, заданный ctx, и вернуть управление
// не позже него — даже если поставщик молчит.
type Client interface {
	Forecast(ctx context.Context, city string) (Forecast, error)
}

// Config — настройки обращения к поставщику.
type Config struct {
	BaseURL     string
	Timeout     time.Duration // на одну попытку
	RetryMax    int           // сколько раз повторить сверх первой попытки
	Concurrency int           // сколько обращений к поставщику одновременно
	Breaker     BreakerConfig
}

// BreakerConfig — настройки размыкателя.
type BreakerConfig struct {
	Failures int           // сколько отказов подряд размыкают цепь
	Cooldown time.Duration // на сколько цепь размыкается
}

// New создаёт клиента.
//
// TODO: вернуть реализацию Client. Она должна выдерживать параллельные
// вызовы: сервис обрабатывает каждый запрос в отдельной горутине.
func New(cfg Config) Client {
	panic("provider.New: не реализовано")
}
__LAB_FILE_EOF__
    ;;
  "internal/weatherapi/api.go")
    cat <<'__LAB_FILE_EOF__'
// Package weatherapi содержит HTTP-слой сервиса: маршрут, обработчик, логи.
package weatherapi

// TODO: собрать маршрут GET /weather из задания, реализовать обработчик
// и запись в логи. Ответ обязан уложиться в бюджет запроса при любом
// поведении поставщика.
__LAB_FILE_EOF__
    ;;
  *) echo "неизвестный файл: $1" >&2; return 1 ;;
  esac
}

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

install_all() {
  if [ -e "$LAB_DIR" ] && [ -n "$(ls -A "$LAB_DIR" 2>/dev/null)" ]; then
    red "каталог $LAB_DIR существует и не пуст"
    echo "Каркас разворачивается только в пустой каталог, чтобы ничего не затереть."
    echo "Сверить содержимое с текущей версией каркаса: $0 --check"
    exit 1
  fi

  for f in "${FILES[@]}"; do
    mkdir -p "$LAB_DIR/$(dirname "$f")"
    emit "$f" > "$LAB_DIR/$f"
  done
  printf '%s\n' "$STARTER_VERSION" > "$LAB_DIR/.starter-version"

  green "каркас развёрнут в $LAB_DIR (версия $STARTER_VERSION, собран $PACKED_AT)"
  echo
  echo "Дальше:"
  echo "  cd $LAB_DIR && make test     # тесты падают, пока не написано хранилище"
  echo "  cd $LAB_DIR && make up       # поднять сервис"
}

check_all() {
  [ -d "$LAB_DIR" ] || { red "каталога $LAB_DIR нет"; exit 1; }

  local have differs=0 missing=0
  have=$(cat "$LAB_DIR/.starter-version" 2>/dev/null || echo "неизвестна")
  echo "версия каркаса в $LAB_DIR: $have"
  echo "версия в этом скрипте:     $STARTER_VERSION"
  echo

  for f in "${FILES[@]}"; do
    if [ ! -f "$LAB_DIR/$f" ]; then
      echo "  нет      $f"
      missing=$((missing + 1))
    elif ! emit "$f" | diff -q - "$LAB_DIR/$f" >/dev/null 2>&1; then
      local mark="изменён"
      case " ${INFRA[*]:-} " in *" $f "*) mark="изменён (служебный)" ;; esac
      echo "  $mark  $f"
      differs=$((differs + 1))
    fi
  done

  if [ $differs -eq 0 ] && [ $missing -eq 0 ]; then
    green "расхождений нет"
    return 0
  fi
  echo
  echo "Изменённые файлы с кодом — это нормально, работа в них и ведётся."
}

# Режим намеренно не описан ни в задании, ни в справке скрипта: неизвестно,
# понадобится ли он вообще. Если каркас придётся править после выдачи —
# рассказать о нём можно будет отдельно.
update_infra() {
  [ -d "$LAB_DIR" ] || { red "каталога $LAB_DIR нет"; exit 1; }
  if [ ${#INFRA[@]} -eq 0 ]; then
    red "для этой практики список сопровождаемых файлов не задан"
    exit 1
  fi

  local changed=0
  for f in "${INFRA[@]}"; do
    if ! emit "$f" | diff -q - "$LAB_DIR/$f" >/dev/null 2>&1; then
      mkdir -p "$LAB_DIR/$(dirname "$f")"
      emit "$f" > "$LAB_DIR/$f"
      echo "  обновлён $f"
      changed=$((changed + 1))
    fi
  done
  printf '%s\n' "$STARTER_VERSION" > "$LAB_DIR/.starter-version"

  if [ $changed -eq 0 ]; then
    green "служебные файлы уже актуальны"
  else
    green "обновлено файлов: $changed, версия $STARTER_VERSION"
  fi
  echo "Файлы с вашим кодом не тронуты."
}

case "${1:-install}" in
  install)  install_all ;;
  --check)  check_all ;;
  --update) update_infra ;;
  -h|--help)
    echo "Использование: $0 [--check]"
    echo "  без аргументов  развернуть каркас в \$LAB_DIR (по умолчанию $LAB_DIR)"
    echo "  --check         показать расхождения с текущей версией каркаса"
    ;;
  *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
esac
