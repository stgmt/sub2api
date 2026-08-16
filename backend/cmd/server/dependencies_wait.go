package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	dependencyWaitAttemptsEnv    = "SUB2API_DEPENDENCY_WAIT_ATTEMPTS"
	dependencyWaitIntervalEnv    = "SUB2API_DEPENDENCY_WAIT_INTERVAL_SECONDS"
	defaultDependencyWaitAttempts = 60
	defaultDependencyWaitInterval = 2 * time.Second
	dependencyDialTimeout         = 2 * time.Second
)

// dependencyWaitConfig resolves the retry budget from env with sane defaults.
func dependencyWaitConfig(getenv func(string) string) (int, time.Duration) {
	attempts := defaultDependencyWaitAttempts
	if raw := strings.TrimSpace(getenv(dependencyWaitAttemptsEnv)); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v > 0 {
			attempts = v
		}
	}

	interval := defaultDependencyWaitInterval
	if raw := strings.TrimSpace(getenv(dependencyWaitIntervalEnv)); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v > 0 {
			interval = time.Duration(v) * time.Second
		}
	}
	return attempts, interval
}

// tcpReachable reports whether addr accepts a TCP connection.
func tcpReachable(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, dependencyDialTimeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// envHostPort reads host/port env vars with defaults matching the Docker
// compose profile and the setup package defaults.
func envHostPort(getenv func(string) string, hostKey, portKey, defaultHost string, defaultPort int) (string, int) {
	host := strings.TrimSpace(getenv(hostKey))
	if host == "" {
		host = defaultHost
	}
	port := defaultPort
	if raw := strings.TrimSpace(getenv(portKey)); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v > 0 {
			port = v
		}
	}
	return host, port
}

func dbHostFromEnv() (string, int) {
	return envHostPort(os.Getenv, "DATABASE_HOST", "DATABASE_PORT", "localhost", 5432)
}

func redisHostFromEnv() (string, int) {
	return envHostPort(os.Getenv, "REDIS_HOST", "REDIS_PORT", "localhost", 6379)
}

// waitForDependencies blocks until postgres and redis accept TCP connections,
// or the retry budget is exhausted. This closes the startup race after a
// Docker daemon restart: compose `depends_on: service_healthy` only applies
// during `docker compose up`, while `restart: unless-stopped` brings all
// containers up concurrently and sub2api could previously crash on
// "acquire migrations lock: dial tcp ... connection refused".
func waitForDependencies(
	getenv func(string) string,
	dbHost string,
	dbPort int,
	redisHost string,
	redisPort int,
) error {
	attempts, interval := dependencyWaitConfig(getenv)
	dbAddr := fmt.Sprintf("%s:%d", dbHost, dbPort)
	redisAddr := fmt.Sprintf("%s:%d", redisHost, redisPort)

	for i := 1; i <= attempts; i++ {
		dbOK := tcpReachable(dbAddr)
		redisOK := tcpReachable(redisAddr)
		if dbOK && redisOK {
			return nil
		}
		if i < attempts {
			log.Printf(
				"Waiting for dependencies (postgres=%v redis=%v), attempt %d/%d, retry in %s",
				dbOK, redisOK, i, attempts, interval,
			)
			time.Sleep(interval)
		}
	}

	return fmt.Errorf(
		"dependencies not ready after %d attempts: postgres %s, redis %s",
		attempts, dbAddr, redisAddr,
	)
}
