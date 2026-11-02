package main

import (
	"net/url"
	"strings"
)

// The SDK does not expose account UUID/region. A copied private item link
// supplies those routing identifiers without accessing any item's contents.
func itemLink(r request) response {
	fail := response{ID: r.ID, Error: "invalid_item_link"}
	u, err := url.Parse(strings.TrimSpace(r.URL))
	if err != nil || u.User != nil || u.Fragment != "" || u.Path != "/i" && u.Path != "/open/i" {
		return fail
	}
	private := u.Scheme == "https" && u.Host == "start.1password.com" && u.Path == "/open/i"
	stored := u.Scheme == "onepassword" && u.Host == "open" && u.Path == "/i"
	if !private && !stored {
		return fail
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return fail
	}
	a, h := q.Get("a"), strings.ToLower(q.Get("h"))
	if a == "" || len(a) > 128 || strings.ContainsAny(a, " /?#&\r\n\t") || r.Item == "" || r.Vault == "" {
		return fail
	}
	region := false
	for _, domain := range []string{"1password.com", "1password.eu", "1password.ca", "1passwordent.com"} {
		if h == domain || strings.HasSuffix(h, "."+domain) {
			region = true
		}
	}
	if !region || strings.ContainsAny(h, "/@:?# \r\n\t") {
		return fail
	}
	if private && (q.Get("v") != r.Vault || q.Get("i") != r.Item) {
		return fail
	}
	if stored && (q.Has("v") && q.Get("v") != r.Vault || q.Has("i") && q.Get("i") != r.Item) {
		return fail
	}
	base := url.URL{Scheme: "onepassword", Host: "open", Path: "/i"}
	routing := url.Values{"a": {a}, "h": {h}}
	base.RawQuery = routing.Encode()
	accountLink := base.String()
	routing.Set("v", r.Vault)
	routing.Set("i", r.Item)
	base.RawQuery = routing.Encode()
	return response{ID: r.ID, Link: base.String(), AccountLink: accountLink}
}
