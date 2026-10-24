package localproxy

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strings"
	"testing"
	"time"
)

func newTestProxy(t *testing.T, dial Dialer) *Server {
	t.Helper()
	s, err := New(0)
	if err != nil {
		t.Fatal(err)
	}
	s.Update(dial)
	t.Cleanup(s.Close)
	return s
}
func connectProxy(t *testing.T, s *Server) net.Conn {
	t.Helper()
	c, err := net.Dial("tcp", s.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(3 * time.Second))
	t.Cleanup(func() { c.Close() })
	return c
}
func testDial(target string) Dialer {
	return func(ctx context.Context, addr string) (net.Conn, error) {
		if addr != "peer.test:80" {
			return nil, errors.New("denied")
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp", target)
	}
}

func TestHTTPStreamingAndDestinationRestriction(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Proxy-Authorization") != "" {
			t.Error("proxy credential leaked")
		}
		body, _ := io.ReadAll(r.Body)
		fmt.Fprintf(w, "%s:%s", r.Host, body)
	}))
	defer origin.Close()
	s := newTestProxy(t, testDial(strings.TrimPrefix(origin.URL, "http://")))
	u, _ := url.Parse("http://" + s.listener.Addr().String())
	transport := &http.Transport{Proxy: http.ProxyURL(u)}
	defer transport.CloseIdleConnections()
	h := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	request, _ := http.NewRequest("POST", "http://peer.test/stream", io.NopCloser(strings.NewReader(strings.Repeat("body", 16384))))
	request.Header.Set("Proxy-Authorization", "secret")
	response, err := h.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if string(body) != "peer.test:"+strings.Repeat("body", 16384) {
		t.Fatalf("bad streamed response, status %d, bytes %d", response.StatusCode, len(body))
	}
	response, err = h.Get("http://forbidden.test/")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 502 {
		t.Fatal(response.Status)
	}
}

func TestRejectOriginFormAndUnsupportedSOCKS(t *testing.T) {
	s := newTestProxy(t, func(context.Context, string) (net.Conn, error) {
		t.Error("unexpected dial")
		return nil, errors.New("denied")
	})
	c := connectProxy(t, s)
	fmt.Fprint(c, "GET /localapi/v0/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	r, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		t.Fatal(err)
	}
	r.Body.Close()
	if r.StatusCode != 400 {
		t.Fatal(r.Status)
	}
	for _, command := range []byte{2, 3} {
		c := connectProxy(t, s)
		for _, b := range []byte{5, 1, 0} {
			c.Write([]byte{b})
		}
		hello := make([]byte, 2)
		io.ReadFull(c, hello)
		if hello[0] != 5 || hello[1] != 0 {
			t.Fatal(hello)
		}
		c.Write([]byte{5, command, 0, 1})
		reply := make([]byte, 10)
		if _, err := io.ReadFull(c, reply); err != nil {
			t.Fatal(err)
		}
		if reply[1] != 7 {
			t.Fatal(reply)
		}
	}
}

func TestSOCKSHalfCloseAndCONNECT(t *testing.T) {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); b, _ := io.ReadAll(c); c.Write(append([]byte("reply:"), b...)) }()
		}
	}()
	s := newTestProxy(t, testDial(ln.Addr().String()))
	for _, protocol := range []string{"socks", "connect"} {
		t.Run(protocol, func(t *testing.T) {
			c := connectProxy(t, s)
			r := bufio.NewReader(c)
			if protocol == "socks" {
				c.Write([]byte{5, 1, 0})
				hello := make([]byte, 2)
				io.ReadFull(r, hello)
				request := append([]byte{5, 1, 0, 3, 9}, []byte("peer.test")...)
				request = append(request, 0, 80)
				c.Write(request)
				reply := make([]byte, 10)
				if _, err := io.ReadFull(r, reply); err != nil {
					t.Fatal(err)
				}
				if reply[1] != 0 {
					t.Fatal(reply)
				}
			} else {
				fmt.Fprint(c, "CONNECT peer.test:80 HTTP/1.1\r\nHost: peer.test:80\r\n\r\n")
				response, err := http.ReadResponse(r, nil)
				if err != nil {
					t.Fatal(err)
				}
				if response.StatusCode != 200 {
					t.Fatal(response.Status)
				}
			}
			c.Write([]byte{0, 1, 2, 255})
			c.(*net.TCPConn).CloseWrite()
			body, err := io.ReadAll(r)
			if err != nil {
				t.Fatal(err)
			}
			if string(body) != "reply:"+string([]byte{0, 1, 2, 255}) {
				t.Fatalf("%v", body)
			}
		})
	}
}

func TestSwitchCancelsPendingDialAndPreservesPort(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	s := newTestProxy(t, func(ctx context.Context, _ string) (net.Conn, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		return nil, ctx.Err()
	})
	port := s.Port()
	c := connectProxy(t, s)
	fmt.Fprint(c, "CONNECT peer.test:80 HTTP/1.1\r\nHost: peer.test:80\r\n\r\n")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("dial not started")
	}
	s.Update(nil)
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("old dial not cancelled")
	}
	if s.Port() != port {
		t.Fatal("port changed")
	}
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("old connection survived")
	}
	other, err := net.Listen("tcp4", s.listener.Addr().String())
	if err == nil {
		other.Close()
		t.Fatal("port was not reserved")
	}
	s.Close()
	if _, err := net.DialTimeout("tcp", s.listener.Addr().String(), time.Second); err == nil {
		t.Fatal("listener survived stop")
	}
}

func TestClientDisconnectCancelsDial(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	s := newTestProxy(t, func(ctx context.Context, _ string) (net.Conn, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		return nil, ctx.Err()
	})
	c := connectProxy(t, s)
	fmt.Fprint(c, "GET http://peer.test/ HTTP/1.1\r\nHost: peer.test\r\n\r\n")
	<-started
	c.Close()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("request cancellation did not reach dial")
	}
}

func TestMappedIPv6SOCKSIsRejectedBeforeDial(t *testing.T) {
	s := newTestProxy(t, func(context.Context, string) (net.Conn, error) {
		t.Error("mapped address reached dialer")
		return nil, errors.New("denied")
	})
	c := connectProxy(t, s)
	c.Write([]byte{5, 1, 0})
	io.ReadFull(c, make([]byte, 2))
	ip := netip.MustParseAddr("::ffff:100.64.0.1").As16()
	request := append([]byte{5, 1, 0, 4}, ip[:]...)
	c.Write(append(request, 0, 80))
	reply := make([]byte, 10)
	if _, err := io.ReadFull(c, reply); err != nil || reply[1] != 2 {
		t.Fatalf("reply %v: %v", reply, err)
	}
}

func TestHTTPUpgradeStreamsAndSwitchClosesBothSides(t *testing.T) {
	originClosed := make(chan struct{})
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		defer close(originClosed)
		rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
		rw.Flush()
		io.Copy(conn, rw)
	}))
	defer origin.Close()
	s := newTestProxy(t, testDial(strings.TrimPrefix(origin.URL, "http://")))
	c := connectProxy(t, s)
	fmt.Fprint(c, "GET http://peer.test/socket HTTP/1.1\r\nHost: peer.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
	r := bufio.NewReader(c)
	response, err := http.ReadResponse(r, nil)
	if err != nil || response.StatusCode != 101 {
		t.Fatalf("upgrade: %v %v", response, err)
	}
	c.Write([]byte{0, 255, 1, 2})
	data := make([]byte, 4)
	if _, err := io.ReadFull(r, data); err != nil || string(data) != string([]byte{0, 255, 1, 2}) {
		t.Fatalf("upgrade stream: %v %v", data, err)
	}
	s.Update(nil)
	if _, err := r.ReadByte(); err == nil {
		t.Fatal("old upgrade survived switch")
	}
	select {
	case <-originClosed:
	case <-time.After(time.Second):
		t.Fatal("upstream upgrade leaked")
	}
	// The same endpoint now belongs to the replacement route. No old bytes replay.
	s.Update(testDial(strings.TrimPrefix(origin.URL, "http://")))
	if s.ActiveConnections() != 0 {
		t.Fatal("old connection count survived switch")
	}
}

func TestHTTPMalformedFramingNeverReachesOrigin(t *testing.T) {
	s := newTestProxy(t, func(context.Context, string) (net.Conn, error) {
		t.Error("malformed request reached dialer")
		return nil, errors.New("denied")
	})
	for _, headers := range []string{
		"Content-Length: 2\r\nContent-Length: 3\r\n",
		"Transfer-Encoding: unknown\r\n",
		"X-Large: " + strings.Repeat("x", 24*1024) + "\r\n",
	} {
		c := connectProxy(t, s)
		fmt.Fprintf(c, "POST http://peer.test/ HTTP/1.1\r\nHost: peer.test\r\n%sConnection: close\r\n\r\n", headers)
		r, err := http.ReadResponse(bufio.NewReader(c), nil)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		if r.StatusCode < 400 {
			t.Fatal(r.Status)
		}
	}
}
