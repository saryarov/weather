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
