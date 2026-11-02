package main

import (
	"golang.org/x/net/idna"
	"golang.org/x/net/publicsuffix"
	"net"
	"net/url"
	"strings"
)

// Only encrypted sites and loopback development servers are eligible.
func origin(raw string) (*url.URL, bool) {
	u, err := url.Parse(raw)
	if err != nil || u.User != nil || u.Opaque != "" || u.Hostname() == "" {
		return nil, false
	}
	host, err := idna.Lookup.ToASCII(strings.ToLower(strings.TrimSuffix(u.Hostname(), ".")))
	if err != nil {
		return nil, false
	}
	ip := net.ParseIP(host)
	local := host == "localhost" || ip != nil && ip.IsLoopback()
	if u.Scheme != "https" && !(u.Scheme == "http" && local) {
		return nil, false
	}
	port := u.Port()
	if u.Scheme == "https" && port == "443" || u.Scheme == "http" && port == "80" {
		port = ""
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port != "" {
		host += ":" + port
	}
	return &url.URL{Scheme: u.Scheme, Host: host}, true
}

func websiteAllows(saved, destination, behavior string) bool {
	if behavior != "ExactDomain" && behavior != "AnywhereOnWebsite" {
		return false
	}
	a, ok := origin(saved)
	if !ok {
		return false
	}
	b, ok := origin(destination)
	if !ok || a.Scheme != b.Scheme || a.Port() != b.Port() {
		return false
	}
	if a.Host == b.Host {
		return true
	}
	if behavior != "AnywhereOnWebsite" || a.Scheme != "https" {
		return false
	}
	// Narrower than matching sibling hosts by registrable domain.
	if _, err := publicsuffix.EffectiveTLDPlusOne(a.Hostname()); err != nil {
		return false
	}
	return strings.HasSuffix(b.Hostname(), "."+a.Hostname())
}
