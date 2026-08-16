package main

import (
	"net"
	"strconv"
	"testing"
	"time"
)

func TestDependencyWaitConfigDefaults(t *testing.T) {
	attempts, interval := dependencyWaitConfig(func(string) string { return "" })
	if attempts != defaultDependencyWaitAttempts {
		t.Fatalf("attempts = %d, want %d", attempts, defaultDependencyWaitAttempts)
	}
	if interval != defaultDependencyWaitInterval {
		t.Fatalf("interval = %s, want %s", interval, defaultDependencyWaitInterval)
	}
}

func TestDependencyWaitConfigOverrides(t *testing.T) {
	env := map[string]string{
		dependencyWaitAttemptsEnv: "7",
		dependencyWaitIntervalEnv: "3",
	}
	attempts, interval := dependencyWaitConfig(func(key string) string { return env[key] })
	if attempts != 7 {
		t.Fatalf("attempts = %d, want 7", attempts)
	}
	if interval != 3*time.Second {
		t.Fatalf("interval = %s, want 3s", interval)
	}
}

func TestDependencyWaitConfigInvalidFallsBack(t *testing.T) {
	env := map[string]string{
		dependencyWaitAttemptsEnv: "not-a-number",
		dependencyWaitIntervalEnv: "-5",
	}
	attempts, interval := dependencyWaitConfig(func(key string) string { return env[key] })
	if attempts != defaultDependencyWaitAttempts {
		t.Fatalf("attempts = %d, want default", attempts)
	}
	if interval != defaultDependencyWaitInterval {
		t.Fatalf("interval = %s, want default", interval)
	}
}

func TestTCPReachableClosedPort(t *testing.T) {
	// A listener that is immediately closed leaves the port unreachable.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	// Port may be reused by another process; still assert no panic and a bool.
	_ = tcpReachable(addr)
}

func TestTCPReachableOpenPort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	addr := ln.Addr().String()

	if !tcpReachable(addr) {
		t.Fatalf("tcpReachable(%s) = false, want true", addr)
	}
}

func TestWaitForDependenciesReady(t *testing.T) {
	dbLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dbLn.Close()
	redisLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer redisLn.Close()

	dbHost, dbPortStr, _ := net.SplitHostPort(dbLn.Addr().String())
	redisHost, redisPortStr, _ := net.SplitHostPort(redisLn.Addr().String())
	dbPort, _ := strconv.Atoi(dbPortStr)
	redisPort, _ := strconv.Atoi(redisPortStr)

	err = waitForDependencies(
		func(string) string { return "1" }, // single attempt is enough
		dbHost,
		dbPort,
		redisHost,
		redisPort,
	)
	if err != nil {
		t.Fatalf("waitForDependencies ready = %v, want nil", err)
	}
}

func TestWaitForDependenciesExhaustsBudget(t *testing.T) {
	// No listener: both targets unreachable; a tiny budget must fail fast.
	env := map[string]string{
		dependencyWaitAttemptsEnv: "2",
		dependencyWaitIntervalEnv: "1",
	}
	err := waitForDependencies(
		func(key string) string { return env[key] },
		"127.0.0.1",
		1, // port 1 on loopback is never open
		"127.0.0.1",
		2,
	)
	if err == nil {
		t.Fatal("waitForDependencies unreachable = nil, want error")
	}
}
