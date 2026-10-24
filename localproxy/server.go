// Copyright (c) GalaxNet Ltd. All rights reserved.
// Package localproxy serves an explicitly enabled, device-loopback TCP proxy.
// It deliberately has no default dialer, DNS resolver, or management endpoint.
package localproxy

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Dialer func(context.Context, string) (net.Conn, error)

type Server struct {
	listener     net.Listener
	httpListener *channelListener
	httpServer   *http.Server
	mu           sync.Mutex
	dial         Dialer
	ctx          context.Context
	cancel       context.CancelFunc
	clients      map[*client]struct{}
	closed       bool
}

type client struct {
	net.Conn
	owner  *Server
	ctx    context.Context
	dial   Dialer
	cancel context.CancelFunc
	active bool // Protected by owner.mu; only successful upstream dials count.
	once   sync.Once
}

type clientKey struct{}
type bufferedClient struct {
	*client
	reader *bufio.Reader
}

func (c *bufferedClient) Read(b []byte) (int, error) { return c.reader.Read(b) }

func (c *client) Close() error {
	var err error
	c.once.Do(func() {
		c.cancel()
		err = c.Conn.Close()
		c.owner.mu.Lock()
		delete(c.owner.clients, c)
		c.owner.mu.Unlock()
	})
	return err
}

func (c *client) connect(parent context.Context, address string) (net.Conn, error) {
	if c.dial == nil {
		return nil, errors.New("route unavailable")
	}
	ctx, cancel := context.WithTimeout(parent, 15*time.Second)
	defer cancel()
	upstream, err := c.dial(ctx, address)
	if err != nil {
		return nil, err
	}
	c.owner.mu.Lock()
	_, alive := c.owner.clients[c]
	if c.ctx.Err() != nil || !alive {
		c.owner.mu.Unlock()
		upstream.Close()
		return nil, context.Canceled
	}
	c.active = true
	c.owner.mu.Unlock()
	return upstream, nil
}

func New(port uint16) (*Server, error) {
	ln, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port))))
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{listener: ln, ctx: ctx, cancel: cancel, clients: make(map[*client]struct{})}
	s.httpListener = &channelListener{address: ln.Addr(), conns: make(chan net.Conn), done: make(chan struct{})}
	s.httpServer = &http.Server{
		Handler: http.HandlerFunc(s.serveHTTP), ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 * 1024,
		ConnContext: func(_ context.Context, conn net.Conn) context.Context {
			c := conn.(*bufferedClient).client
			return context.WithValue(c.ctx, clientKey{}, c)
		},
	}
	go s.httpServer.Serve(s.httpListener)
	go s.accept()
	return s, nil
}

func (s *Server) Port() uint16 { return uint16(s.listener.Addr().(*net.TCPAddr).Port) }

// Update invalidates all accepted connections and pending dials while preserving
// the listening socket/port. No queued client data is replayed to the new route.
func (s *Server) Update(dial Dialer) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.cancel()
	s.ctx, s.cancel = context.WithCancel(context.Background())
	s.dial = dial
	clients := make([]*client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.Unlock()
	for _, c := range clients {
		c.Close()
	}
}

func (s *Server) ActiveConnections() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for c := range s.clients {
		if c.active {
			n++
		}
	}
	return n
}

func (s *Server) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.cancel()
	clients := make([]*client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.Unlock()
	s.listener.Close()
	s.httpListener.Close()
	s.httpServer.Close()
	for _, c := range clients {
		c.Close()
	}
}

func (s *Server) accept() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		if s.closed || s.dial == nil || len(s.clients) >= 64 {
			s.mu.Unlock()
			conn.Close()
			continue
		}
		ctx, cancel := context.WithCancel(s.ctx)
		c := &client{Conn: conn, owner: s, ctx: ctx, cancel: cancel, dial: s.dial}
		s.clients[c] = struct{}{}
		s.mu.Unlock()
		go s.dispatch(c)
	}
}

func (s *Server) dispatch(c *client) {
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReader(c)
	b, err := r.Peek(1)
	if err != nil {
		c.Close()
		return
	}
	if b[0] == 5 {
		defer c.Close()
		serveSOCKS(c, r)
		return
	}
	select {
	case s.httpListener.conns <- &bufferedClient{client: c, reader: r}:
	case <-c.ctx.Done():
		c.Close()
	case <-s.httpListener.done:
		c.Close()
	}
}

func serveSOCKS(c *client, r *bufio.Reader) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(r, header); err != nil || header[0] != 5 || header[1] == 0 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(r, methods); err != nil {
		return
	}
	allowed := false
	for _, method := range methods {
		if method == 0 {
			allowed = true
		}
	}
	if !allowed {
		c.Write([]byte{5, 255})
		return
	}
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return
	}
	request := make([]byte, 4)
	if _, err := io.ReadFull(r, request); err != nil || request[0] != 5 || request[2] != 0 {
		return
	}
	reply := func(code byte) { c.Write([]byte{5, code, 0, 1, 0, 0, 0, 0, 0, 0}) }
	if request[1] != 1 {
		reply(7)
		return
	}
	var host string
	switch request[3] {
	case 1, 4:
		n := 4
		if request[3] == 4 {
			n = 16
		}
		ip := make([]byte, n)
		if _, err := io.ReadFull(r, ip); err != nil {
			return
		}
		address, _ := netip.AddrFromSlice(ip)
		if address.Is4In6() {
			reply(2)
			return
		}
		host = address.String()
	case 3:
		n, err := r.ReadByte()
		if err != nil || n == 0 {
			return
		}
		name := make([]byte, int(n))
		if _, err := io.ReadFull(r, name); err != nil {
			return
		}
		host = string(name)
	default:
		reply(8)
		return
	}
	port := make([]byte, 2)
	if _, err := io.ReadFull(r, port); err != nil {
		return
	}
	upstream, err := c.connect(c.ctx, net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(port)))))
	if err != nil {
		reply(2)
		return
	}
	defer upstream.Close()
	c.SetReadDeadline(time.Time{})
	reply(0)
	pump(c, r, upstream)
}

func pump(c *client, reader io.Reader, upstream net.Conn) {
	stop := context.AfterFunc(c.ctx, func() { upstream.Close(); c.Close() })
	defer stop()
	done := make(chan struct{})
	go func() {
		io.Copy(upstream, reader)
		if w, ok := upstream.(interface{ CloseWrite() error }); ok {
			w.CloseWrite()
		}
		close(done)
	}()
	io.Copy(c, upstream)
	if w, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		w.CloseWrite()
	}
	<-done
}

func (s *Server) serveHTTP(w http.ResponseWriter, r *http.Request) {
	c := r.Context().Value(clientKey{}).(*client)
	if r.Method == http.MethodConnect {
		if r.URL.User != nil || strings.ContainsAny(r.Host, "/?#") {
			http.Error(w, "Invalid target", 400)
			return
		}
		upstream, err := c.connect(r.Context(), r.Host)
		if err != nil {
			http.Error(w, "Proxy destination unavailable", 502)
			return
		}
		defer upstream.Close()
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		if _, err := rw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
			return
		}
		if err := rw.Flush(); err != nil {
			return
		}
		c.SetDeadline(time.Time{})
		pump(c, rw, upstream)
		return
	}
	if !r.URL.IsAbs() || r.URL.Scheme != "http" || r.URL.User != nil || r.URL.Fragment != "" || r.URL.Host != r.Host {
		http.Error(w, "Absolute HTTP proxy request required", 400)
		return
	}
	// The standard library handles HTTP framing, streaming, hop-by-hop headers,
	// cancellation and WebSocket upgrades. Never use ProxyFromEnvironment.
	transport := &http.Transport{
		Proxy: nil, DisableKeepAlives: true, ResponseHeaderTimeout: 30 * time.Second,
		MaxResponseHeaderBytes: 32 * 1024,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := c.connect(ctx, address)
			if err != nil {
				return nil, err
			}
			stop := context.AfterFunc(ctx, func() { conn.Close() })
			return &cancelConn{Conn: conn, stop: stop}, nil
		},
	}
	defer transport.CloseIdleConnections()
	proxy := httputil.ReverseProxy{
		Rewrite: func(p *httputil.ProxyRequest) {
			p.Out.Header.Del("Proxy-Authorization")
			p.Out.Header.Del("Proxy-Connection")
		},
		Transport: transport,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, "Proxy destination unavailable", 502)
		},
	}
	proxy.ServeHTTP(w, r)
}

type cancelConn struct {
	net.Conn
	stop func() bool
}

func (c *cancelConn) Close() error { c.stop(); return c.Conn.Close() }

// ReverseProxy's upgrade handling requires its transport connection's CloseWrite.
func (c *cancelConn) CloseWrite() error {
	if w, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return w.CloseWrite()
	}
	return nil
}

type channelListener struct {
	address net.Addr
	conns   chan net.Conn
	done    chan struct{}
	once    sync.Once
}

func (l *channelListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}
func (l *channelListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *channelListener) Addr() net.Addr { return l.address }
