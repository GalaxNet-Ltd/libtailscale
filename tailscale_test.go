package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"testing"
	"time"

	"github.com/tailscale/libtailscale/tsnetctest"
)

func TestConn(t *testing.T) {
	tsnetctest.RunTestConn(t)

	// RunTestConn cleans up after itself, so there shouldn't be
	// anything left in the global maps.

	servers.mu.Lock()
	rem := len(servers.m)
	servers.mu.Unlock()

	if rem > 0 {
		t.Fatalf("want no remaining tsnet objects, got %d", rem)
	}

	var remConns, remLns int

	for i := 0; i < 50; i++ {
		conns.mu.Lock()
		remConns = len(conns.m)
		conns.mu.Unlock()

		listeners.mu.Lock()
		remLns = len(listeners.m)
		listeners.mu.Unlock()

		if remConns == 0 && remLns == 0 {
			break
		}

		// We are waiting for cleanup goroutines to finish.
		//
		// libtailscale closes one side of a socketpair and
		// then Go responds to the other side being unreadable
		// by closing the connections and listeners.
		//
		// This is inherently asynchronous.
		// Without ditching the standard close(2) and having our
		// own close functions.
		//
		// So we spin for a while
		time.Sleep(100 * time.Millisecond)
	}

	if remConns > 0 {
		t.Errorf("want no remaining tsnet_conn objects, got %d", remConns)
	}

	if remLns > 0 {
		t.Errorf("want no remaining tsnet_listener objects, got %d", remLns)
	}
}

func TestExtractIP(t *testing.T) {
	ipv4 := "1.23.33.4:12343"
	ipv6 := "[1::2234::34fc::44]:56576"

	got4 := extractIP(ipv4)
	got6 := extractIP(ipv6)

	want4 := "1.23.33.4"
	want6 := "[1::2234::34fc::44]"

	if got4 != want4 {
		t.Errorf("ipv4 port stripping failed")
	}

	if got6 != want6 {
		t.Errorf("ipv6 port stripping failed %s != %s", got6, want6)
	}
}

func TestLogFDBorrowedAcrossServerReplacement(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("create log pipe: %v", err)
	}
	t.Cleanup(func() {
		_ = reader.Close()
		_ = writer.Close()
	})

	for cycle := 0; cycle < 2; cycle++ {
		sd := TsnetNewServer()
		s := getServer(sd)
		if s == nil {
			t.Fatalf("cycle %d: missing server", cycle)
		}
		if err := s.setLogFD(int(writer.Fd())); err != nil {
			t.Fatalf("cycle %d: set log fd: %v", cycle, err)
		}

		ownedLogFile := s.logFile
		if ownedLogFile == nil {
			t.Fatalf("cycle %d: missing owned log file", cycle)
		}
		if ownedLogFile.Fd() == writer.Fd() {
			t.Fatalf("cycle %d: libtailscale retained the caller's fd instead of a duplicate", cycle)
		}

		wantLog := fmt.Sprintf("server log %d\n", cycle)
		s.s.Logf("server log %d", cycle)
		requirePipeRoundTrip(t, reader, nil, wantLog)

		if got := TsnetClose(sd); got != 0 {
			t.Fatalf("cycle %d: close server returned %d", cycle, got)
		}
		if s.logFile != nil {
			t.Fatalf("cycle %d: server retained its owned log file after close", cycle)
		}
		if _, err := ownedLogFile.Write([]byte("closed")); !errors.Is(err, os.ErrClosed) {
			t.Fatalf("cycle %d: owned duplicate was not closed: %v", cycle, err)
		}

		runtime.GC()
		requirePipeRoundTrip(t, reader, writer, fmt.Sprintf("caller log %d\n", cycle))
	}
}

func TestSetLogFDReplacesAndDiscardsOwnedDuplicate(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("create log pipe: %v", err)
	}
	t.Cleanup(func() {
		_ = reader.Close()
		_ = writer.Close()
	})

	sd := TsnetNewServer()
	s := getServer(sd)
	if s == nil {
		t.Fatal("missing server")
	}
	t.Cleanup(func() {
		if getServer(sd) != nil {
			_ = TsnetClose(sd)
		}
	})
	if err := s.setLogFD(int(writer.Fd())); err != nil {
		t.Fatalf("set first log fd: %v", err)
	}
	first := s.logFile

	if err := s.setLogFD(int(writer.Fd())); err != nil {
		t.Fatalf("replace log fd: %v", err)
	}
	second := s.logFile
	if second == nil || second == first {
		t.Fatal("replacement did not install a new owned duplicate")
	}
	if _, err := first.Write([]byte("closed")); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("replaced duplicate was not closed: %v", err)
	}

	if err := s.setLogFD(-1); err != nil {
		t.Fatalf("discard log fd: %v", err)
	}
	if s.logFile != nil {
		t.Fatal("discard retained the owned duplicate")
	}
	if _, err := second.Write([]byte("closed")); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("discarded duplicate was not closed: %v", err)
	}
	if got := TsnetClose(sd); got != 0 {
		t.Fatalf("close server returned %d", got)
	}

	runtime.GC()
	requirePipeRoundTrip(t, reader, writer, "caller still open\n")
}

func requirePipeRoundTrip(t *testing.T, reader, writer *os.File, message string) {
	t.Helper()
	if writer != nil {
		if _, err := writer.Write([]byte(message)); err != nil {
			t.Fatalf("write caller's log fd: %v", err)
		}
	}

	got := make([]byte, len(message))
	if _, err := io.ReadFull(reader, got); err != nil {
		t.Fatalf("read log pipe: %v", err)
	}
	if string(got) != message {
		t.Fatalf("log pipe read %q, want %q", got, message)
	}
}
