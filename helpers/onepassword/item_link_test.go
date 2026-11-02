package main

import (
	"context"
	"net/url"
	"testing"
)

func TestItemLinkUsesCopiedAccountRouting(t *testing.T) {
	s := service{backend: &fakeBackend{}}
	r := s.handle(context.Background(), request{Command: "item-link", URL: "https://start.1password.com/open/i?a=account-uuid&h=example.1password.eu&v=v&i=i", Vault: "v", Item: "i"})
	data := responseJSON(r)
	if r.Error != "" || data["link"] == nil {
		t.Fatal("copied private link must open the selected item")
	}
	u, err := url.Parse(data["link"].(string))
	if err != nil || u.Scheme != "onepassword" || u.Host != "open" || u.Path != "/i" || u.Query().Get("i") != "i" || u.Query().Get("a") != "account-uuid" {
		t.Fatal("wrong item routing")
	}
	account := data["accountLink"].(string)
	base, _ := url.Parse(account)
	if base.Query().Has("i") || base.Query().Has("v") {
		t.Fatal("remember account routing only")
	}
	r = s.handle(context.Background(), request{Command: "item-link", URL: account, Vault: "other-vault", Item: "other-item"})
	data = responseJSON(r)
	if r.Error != "" || data["link"] == nil {
		t.Fatal("saved routing must work for other items")
	}
	u, _ = url.Parse(data["link"].(string))
	if u.Query().Get("v") != "other-vault" || u.Query().Get("i") != "other-item" {
		t.Fatal("must open selected IDs")
	}
}
func TestItemLinkRejectsWrongAccountEvidence(t *testing.T) {
	s := service{backend: &fakeBackend{}}
	for _, link := range []string{"https://start.1password.com/open/i?a=a&h=my.1password.com&v=other&i=i", "https://evil.test/open/i?a=a&h=my.1password.com&v=v&i=i", "https://start.1password.com/open/i?a=a&h=evil.test&v=v&i=i", "https://start.1password.com/open/i?h=my.1password.com&v=v&i=i", "javascript:alert(1)"} {
		r := s.handle(context.Background(), request{Command: "item-link", URL: link, Vault: "v", Item: "i"})
		if r.Error != "invalid_item_link" {
			t.Fatal("must reject invalid, mismatched, or incomplete private links")
		}
	}
}
