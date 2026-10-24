package main

import (
	"net/netip"
	"testing"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/key"
)

func TestLocalProxyPeerResolution(t *testing.T) {
	a, b := key.NewNode().Public(), key.NewNode().Public()
	status := &ipnstate.Status{Peer: map[key.NodePublic]*ipnstate.PeerStatus{
		a: {DNSName: "host.example.ts.net.", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.2"), netip.MustParseAddr("fd7a:115c:a1e0::2")}},
	}}
	for _, host := range []string{"HOST.example.ts.net.", "host", "100.64.0.2", "fd7a:115c:a1e0::2"} {
		if _, err := resolveLocalProxyPeer(status, host); err != nil {
			t.Fatalf("%s: %v", host, err)
		}
	}
	for _, host := range []string{"127.0.0.1", "localhost", "::1", "::ffff:100.64.0.2", "169.254.1.1", "100.64.0.3", "example.com", "0x7f000001", "host..", "host/evil"} {
		if _, err := resolveLocalProxyPeer(status, host); err == nil {
			t.Fatalf("allowed %s", host)
		}
	}
	status.Peer[b] = &ipnstate.PeerStatus{DNSName: "host.other.ts.net.", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.3")}}
	if _, err := resolveLocalProxyPeer(status, "host"); err == nil {
		t.Fatal("ambiguous short name allowed")
	}
	status.Self = &ipnstate.PeerStatus{TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.2")}}
	if _, err := resolveLocalProxyPeer(status, "100.64.0.2"); err == nil {
		t.Fatal("self destination allowed")
	}
}
