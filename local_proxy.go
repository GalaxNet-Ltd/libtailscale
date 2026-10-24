package main

/*
#include <errno.h>
*/
import "C"

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"

	"github.com/tailscale/libtailscale/localproxy"
	"tailscale.com/ipn/ipnstate"
)

// NOVA_MOD: Independent local-app proxy; the authenticated Loopback/LocalAPI
// endpoint is never exposed or modified. Entries own their listener, not tsnet.
var localProxies = struct {
	sync.Mutex
	next    int
	servers map[int]*localproxy.Server
}{servers: make(map[int]*localproxy.Server)}

//export TsnetLocalProxyStart
func TsnetLocalProxyStart(port C.int, idOut, portOut *C.int) C.int {
	if port < 0 || port > 65535 || idOut == nil || portOut == nil {
		return C.EINVAL
	}
	s, err := localproxy.New(uint16(port))
	if err != nil {
		return C.EADDRINUSE
	}
	localProxies.Lock()
	defer localProxies.Unlock()
	localProxies.next++
	id := localProxies.next
	localProxies.servers[id] = s
	*idOut = C.int(id)
	*portOut = C.int(s.Port())
	return 0
}

//export TsnetLocalProxyRoute
func TsnetLocalProxyRoute(id, node C.int) C.int {
	localProxies.Lock()
	defer localProxies.Unlock()
	p := localProxies.servers[int(id)]
	if p == nil {
		return C.EBADF
	}
	s := getServer(node)
	if s == nil {
		p.Update(nil)
		return 0
	}
	p.Update(func(ctx context.Context, address string) (net.Conn, error) {
		host, portText, err := net.SplitHostPort(address)
		port, portErr := strconv.Atoi(portText)
		if err != nil || portErr != nil || port < 1 || port > 65535 {
			return nil, errors.New("invalid destination")
		}
		lc, err := s.s.LocalClient()
		if err != nil {
			return nil, err
		}
		status, err := lc.Status(ctx)
		if err != nil || status == nil || status.BackendState != "Running" {
			return nil, errors.New("tailnet unavailable")
		}
		target, err := resolveLocalProxyPeer(status, host)
		if err != nil {
			return nil, err
		}
		return s.s.Dial(ctx, "tcp", net.JoinHostPort(target.String(), strconv.Itoa(port)))
	})
	return 0
}

//export TsnetLocalProxyStats
func TsnetLocalProxyStats(id C.int) C.int {
	localProxies.Lock()
	defer localProxies.Unlock()
	p := localProxies.servers[int(id)]
	if p == nil {
		return -1
	}
	return C.int(p.ActiveConnections())
}

//export TsnetLocalProxyStop
func TsnetLocalProxyStop(id C.int) {
	localProxies.Lock()
	p := localProxies.servers[int(id)]
	delete(localProxies.servers, int(id))
	localProxies.Unlock()
	if p != nil {
		p.Close()
	}
}

func resolveLocalProxyPeer(status *ipnstate.Status, host string) (netip.Addr, error) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	literal, literalErr := netip.ParseAddr(host)
	var target netip.Addr
	matchedKey := ""
	for key, peer := range status.Peer {
		name := strings.ToLower(strings.TrimSuffix(peer.DNSName, "."))
		match := literalErr != nil && name != "" && (host == name || host == strings.Split(name, ".")[0])
		for _, ip := range peer.TailscaleIPs {
			if literalErr == nil && ip == literal {
				match = true
			}
		}
		if !match {
			continue
		}
		if matchedKey != "" && matchedKey != key.String() {
			return netip.Addr{}, errors.New("ambiguous peer name")
		}
		matchedKey = key.String()
		for _, ip := range peer.TailscaleIPs {
			if literalErr == nil && ip != literal {
				continue
			}
			if ip.IsGlobalUnicast() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !ip.Is4In6() {
				target = ip
				break
			}
		}
	}
	if !target.IsValid() {
		return netip.Addr{}, errors.New("destination is not a current peer")
	}
	if status.Self != nil {
		for _, ip := range status.Self.TailscaleIPs {
			if ip == target {
				return netip.Addr{}, errors.New("self destination denied")
			}
		}
	}

	return target, nil
}
