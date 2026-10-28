package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"syscall"
	"tailscale.com/client/local"
	"tailscale.com/net/memnet"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/types/logger"
)

func localAPITestNode(t *testing.T) (int32, func()) {
	t.Helper()
	control := httptest.NewServer(http.NotFoundHandler())
	t.Cleanup(control.Close)
	sd := TsnetNewServer()
	s := getServer(sd)
	s.s.Dir = t.TempDir()
	s.s.Hostname = "localapi-test"
	s.s.ControlURL = control.URL
	s.s.DisableLogTail = true
	s.s.Logf = logger.Discard
	s.s.UserLogf = logger.Discard
	if code := TsnetStart(sd); code != 0 {
		t.Fatalf("start: %d", code)
	}
	var once sync.Once
	closeNode := func() {
		once.Do(func() {
			if code := TsnetClose(sd); code != 0 {
				t.Errorf("close: %d", code)
			}
		})
	}
	t.Cleanup(closeNode)
	return int32(sd), closeNode
}

func localAPITestStart(t *testing.T, sd int32, method, path string, body []byte, mask *ipn.NotifyWatchOpt, timeout time.Duration) (uint64, <-chan localAPIEvent) {
	t.Helper()
	events := make(chan localAPIEvent, 128)
	id, err := startLocalAPIOperation(sd, method, path, body, timeout, mask, func(e localAPIEvent) { events <- e })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cancelLocalAPIOperation(id) })
	return id, events
}

func localAPITestNext(t *testing.T, events <-chan localAPIEvent, kind int) localAPIEvent {
	t.Helper()
	select {
	case e := <-events:
		if e.kind != kind {
			t.Fatalf("event = %+v, want kind %d", e, kind)
		}
		return e
	case <-time.After(5 * time.Second):
		t.Fatal("timed out awaiting callback")
	}
	return localAPIEvent{}
}

func TestLocalAPIRequestStatusBodyAndMutation(t *testing.T) {
	sd, _ := localAPITestNode(t)
	for _, tc := range []struct {
		method, path, body string
		status             int
	}{
		{"GET", "/localapi/v0/status?peers=false", "", 200},
		{"PATCH", "/localapi/v0/prefs", `{"Hostname":"in-process-test","HostnameSet":true}`, 200},
		{"GET", "/localapi/v0/does-not-exist", "", 404},
	} {
		_, events := localAPITestStart(t, sd, tc.method, tc.path, []byte(tc.body), nil, 5*time.Second)
		if got := localAPITestNext(t, events, localAPIHeaders).status; got != tc.status {
			t.Errorf("%s status %d", tc.path, got)
		}
		data := localAPITestNext(t, events, localAPIData).data
		if len(data) == 0 {
			t.Error("missing response/error body")
		}
		if tc.status == 200 && !json.Valid(data) {
			t.Error("invalid JSON response")
		}
		if e := localAPITestNext(t, events, localAPIComplete); e.status != 0 {
			t.Errorf("request failed: %+v", e)
		}
	}
}

func TestLocalAPIWatchSnapshotIdleCancellationAndReplacement(t *testing.T) {
	sd, _ := localAPITestNode(t)
	mask := ipn.NotifyInitialState | ipn.NotifyInitialNetMap
	id, events := localAPITestStart(t, sd, "GET", "/localapi/v0/watch-ipn-bus", nil, &mask, 150*time.Millisecond)
	localAPITestNext(t, events, localAPIHeaders)
	initial := localAPITestNext(t, events, localAPIData)
	var notify ipn.Notify
	if err := json.Unmarshal(initial.data, &notify); err != nil || notify.State == nil {
		t.Fatalf("initial state missing: %s %v", initial.data, err)
	}
	// An accepted watch has no lifetime deadline, even beyond its startup limit.
	time.Sleep(300 * time.Millisecond)
	select {
	case e := <-events:
		if e.kind == localAPIComplete {
			t.Fatalf("idle watch expired: %+v", e)
		}
	default:
	}
	cancelLocalAPIOperation(id)
	for {
		e := <-events
		if e.kind == localAPIComplete {
			if e.status != int(syscall.ECANCELED) {
				t.Fatalf("cancel = %+v", e)
			}
			break
		}
	}
	cancelLocalAPIOperation(id)
	// Cancelling an old operation never cancels the replacement on the same node.
	replacement, next := localAPITestStart(t, sd, "GET", "/localapi/v0/watch-ipn-bus", nil, &mask, time.Second)
	if replacement == id {
		t.Fatal("reused operation ID")
	}
	localAPITestNext(t, next, localAPIHeaders)
	localAPITestNext(t, next, localAPIData)
	select {
	case e := <-events:
		t.Fatalf("callback after terminal: %+v", e)
	default:
	}
}

func TestLocalAPINodeCloseCancelsOnlyOwnedOperations(t *testing.T) {
	old, closeOld := localAPITestNode(t)
	next, _ := localAPITestNode(t)
	mask := ipn.NotifyInitialState
	_, oldEvents := localAPITestStart(t, old, "GET", "/localapi/v0/watch-ipn-bus", nil, &mask, time.Second)
	_, nextEvents := localAPITestStart(t, next, "GET", "/localapi/v0/watch-ipn-bus", nil, &mask, time.Second)
	for _, events := range []<-chan localAPIEvent{oldEvents, nextEvents} {
		localAPITestNext(t, events, localAPIHeaders)
		localAPITestNext(t, events, localAPIData)
	}
	closeOld()
	for {
		e := <-oldEvents
		if e.kind == localAPIComplete {
			if e.status != int(syscall.EBADF) {
				t.Fatalf("close = %+v", e)
			}
			break
		}
	}
	_, request := localAPITestStart(t, next, "GET", "/localapi/v0/status", nil, nil, time.Second)
	localAPITestNext(t, request, localAPIHeaders)
	localAPITestNext(t, request, localAPIData)
	if e := localAPITestNext(t, request, localAPIComplete); e.status != 0 {
		t.Fatal(e)
	}
	_, err := startLocalAPIOperation(old, "GET", "/localapi/v0/status", nil, time.Second, nil, func(localAPIEvent) { t.Error("closed-node callback") })
	if !errors.Is(err, syscall.EBADF) {
		t.Fatalf("closed node: %v", err)
	}
}

func TestLocalAPIValidationAndCloseRegistrationRace(t *testing.T) {
	sd, closeNode := localAPITestNode(t)
	for _, path := range []string{"https://example.com/localapi/v0/status", "//example.com/localapi/v0/status", "/status", "/localapi/v0/status\r\n"} {
		_, err := startLocalAPIOperation(sd, "GET", path, nil, time.Second, nil, func(localAPIEvent) { t.Error("invalid-path callback") })
		if !errors.Is(err, syscall.EINVAL) {
			t.Errorf("path %q: %v", path, err)
		}
	}
	var workers sync.WaitGroup
	for range 32 {
		workers.Go(func() {
			done := make(chan struct{})
			_, err := startLocalAPIOperation(sd, "GET", "/localapi/v0/status", nil, time.Second, nil, func(e localAPIEvent) {
				if e.kind == localAPIComplete {
					close(done)
				}
			})
			if errors.Is(err, syscall.EBADF) {
				return
			}
			if err != nil {
				t.Error(err)
				return
			}
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Error("operation survived close")
			}
		})
	}
	closeNode()
	workers.Wait()
}

// Exercise deadlines and framing through the same memnet + HTTP transport as
// tsnet.LocalClient, with a controlled handler for stalled/fragmented responses.
func TestLocalAPIInMemoryDeadlinesAndFraming(t *testing.T) {
	for _, scenario := range []string{"request-body-stall", "watch-headers-stall", "watch-initial-stall", "fragmented-watch", "oversized-body"} {
		t.Run(scenario, func(t *testing.T) {
			listener := memnet.Listen("local-tailscaled.sock:80")
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch scenario {
				case "request-body-stall", "watch-initial-stall":
					w.WriteHeader(200)
					w.(http.Flusher).Flush()
					<-r.Context().Done()
				case "watch-headers-stall":
					<-r.Context().Done()
				case "fragmented-watch":
					for _, part := range []string{`{"Sta`, "te\":6}\n{\"State\":4}\n"} {
						io.WriteString(w, part)
						w.(http.Flusher).Flush()
					}
				case "oversized-body":
					block := make([]byte, 1<<20)
					for range 33 {
						if _, err := w.Write(block); err != nil {
							return
						}
					}
				}
			})}
			go server.Serve(listener)
			defer server.Close()
			lc := &local.Client{Dial: listener.Dial}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var mask *ipn.NotifyWatchOpt
			if scenario != "request-body-stall" && scenario != "oversized-body" {
				value := ipn.NotifyInitialState
				mask = &value
			}
			timeout := 200 * time.Millisecond
			if scenario == "oversized-body" || scenario == "fragmented-watch" {
				timeout = 5 * time.Second
			}
			timer := time.AfterFunc(timeout, cancel)
			defer timer.Stop()
			var events []localAPIEvent
			err := runLocalAPIClient(ctx, lc, "GET", "/localapi/v0/status", nil, mask, timer.Stop, func(e localAPIEvent) { events = append(events, e) })
			if scenario == "fragmented-watch" {
				if !errors.Is(err, io.EOF) {
					t.Fatalf("end = %v", err)
				}
				if len(events) != 3 {
					t.Fatalf("events = %+v", events)
				}
				for i, state := range []ipn.State{ipn.Running, ipn.Stopped} {
					var n ipn.Notify
					if err := json.Unmarshal(events[i+1].data, &n); err != nil || n.State == nil || *n.State != state {
						t.Errorf("notify: %+v, %v", n, err)
					}
				}
			} else if scenario == "oversized-body" {
				if !errors.Is(err, syscall.EFBIG) {
					t.Fatalf("oversized = %v", err)
				}
				if len(events) != 1 {
					t.Fatalf("oversized body was delivered: %d events", len(events))
				}
			} else if !errors.Is(err, context.Canceled) {
				t.Fatalf("stalled operation: %v", err)
			}
		})
	}
}
