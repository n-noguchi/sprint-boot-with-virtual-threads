package main

import (
	"io"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
)

var (
	client    *http.Client
	api2URL   string
	api2Delay time.Duration
	sem       chan struct{}
)

func concurrencyMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if sem != nil {
			sem <- struct{}{}
			defer func() { <-sem }()
		}
		c.Next()
	}
}

func api1Handler(c *gin.Context) {
	resp, err := client.Get(api2URL + "/api2")
	if err != nil {
		c.String(http.StatusBadGateway, "error: %v", err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	c.Data(resp.StatusCode, "text/plain", body)
}

func api2Handler(c *gin.Context) {
	time.Sleep(api2Delay)
	c.String(http.StatusOK, "ok")
}

func threadHandler(c *gin.Context) {
	c.String(http.StatusOK, "go-routine (Go handles every request in a goroutine)")
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func main() {
	api2URL = os.Getenv("API2_URL")
	if api2URL == "" {
		api2URL = "http://localhost:8080"
	}
	api2Delay = time.Duration(envInt("API2_DELAY_MS", 200)) * time.Millisecond

	if mc := envInt("API_MAX_CONCURRENCY", 0); mc > 0 {
		sem = make(chan struct{}, mc)
	}

	client = &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        1000,
			MaxIdleConnsPerHost: 1000,
		},
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(concurrencyMiddleware())
	r.GET("/api1", api1Handler)
	r.GET("/api2", api2Handler)
	r.GET("/thread", threadHandler)
	r.Run(":8080")
}
