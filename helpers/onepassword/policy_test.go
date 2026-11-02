package main

import "testing"

func TestWebsiteMatching(t *testing.T) {
	tests := []struct {
		name, saved, destination, behavior string
		want                               bool
	}{
		{"exact hostname", "https://example.com", "https://example.com/login", "ExactDomain", true},
		{"normalize default port", "https://EXAMPLE.com:443", "https://example.com/login", "ExactDomain", true},
		{"no sibling with exact rule", "https://example.com", "https://login.example.com", "ExactDomain", false},
		{"explicit child domain", "https://example.com", "https://login.example.com", "AnywhereOnWebsite", true},
		{"no suffix trick", "https://example.com", "https://badexample.com", "AnywhereOnWebsite", false},
		{"no extra suffix", "https://example.com", "https://example.com.evil.test", "AnywhereOnWebsite", false},
		{"never fill", "https://example.com", "https://example.com", "Never", false},
		{"no downgrade", "https://example.com", "http://example.com", "ExactDomain", false},
		{"local development exact port", "http://localhost:3000", "http://localhost:3000/signup", "ExactDomain", true},
		{"different local port", "http://localhost:3000", "http://localhost:3001", "ExactDomain", false},
		{"remote plaintext denied", "http://example.com", "http://example.com", "ExactDomain", false},
		{"no userinfo", "https://example.com", "https://example.com@evil.test", "AnywhereOnWebsite", false},
		{"invalid scheme", "https://example.com", "javascript:alert(1)", "ExactDomain", false},
		{"unknown behavior fails closed", "https://example.com", "https://example.com", "unknown", false},
		{"broad public suffix rejected", "https://co.uk", "https://bank.co.uk", "AnywhereOnWebsite", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := websiteAllows(tt.saved, tt.destination, tt.behavior); got != tt.want {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
		})
	}
}
