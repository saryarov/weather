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
