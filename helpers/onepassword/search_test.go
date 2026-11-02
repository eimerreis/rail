package main

import (
	"context"
	"encoding/json"
	"fmt"
	op "github.com/1password/onepassword-sdk-go"
	"testing"
	"time"
)

// A fixed per-call cost makes SDK round trips measurable without a real vault.
type searchBackend struct {
	fakeBackend
	records                    []op.ItemOverview
	calls, individual, batches int
	delay                      time.Duration
	listFailure                bool
}

func (f *searchBackend) tick() { f.calls++; time.Sleep(f.delay) }
func (f *searchBackend) vaults(context.Context) ([]op.VaultOverview, error) {
	f.tick()
	return []op.VaultOverview{{ID: "v", Title: "Work"}}, nil
}
func (f *searchBackend) items(context.Context, string) ([]op.ItemOverview, error) {
	f.tick()
	if f.listFailure {
		return nil, fmt.Errorf("unavailable")
	}
	return f.records, nil
}
func (f *searchBackend) username(context.Context, string, string) (string, error) {
	f.tick()
	f.individual++
	return "user@example.com", nil
}
func (f *searchBackend) usernames(_ context.Context, items []searchItem) (map[string]string, error) {
	f.tick()
	f.batches++
	names := map[string]string{}
	for _, item := range items {
		names[item.Vault+"/"+item.ID] = "user@example.com"
	}
	return names, nil
}
func searchFixture(n int) *searchBackend {
	f := &searchBackend{}
	for i := 0; i < n; i++ {
		f.records = append(f.records, op.ItemOverview{ID: fmt.Sprint(i), VaultID: "v", Title: fmt.Sprintf("Login %04d", i), Category: op.ItemCategoryLogin, State: op.ItemStateActive, Websites: []op.Website{{URL: "https://example.com", AutofillBehavior: op.AutofillBehaviorExactDomain}}})
	}
	return f
}
func searchRequest(fields string) request {
	var r request
	if err := json.Unmarshal([]byte(fields), &r); err != nil {
		panic(err)
	}
	return r
}
func responseJSON(r response) map[string]any {
	data, _ := json.Marshal(r)
	var result map[string]any
	_ = json.Unmarshal(data, &result)
	return result
}
func TestSearchLatencyProbe(t *testing.T) {
	f := searchFixture(24)
	f.delay = 5 * time.Millisecond
	s := service{backend: f}
	for _, name := range []string{"cold", "warm"} {
		before := f.calls
		start := time.Now()
		r := s.handle(context.Background(), request{Command: "list", URL: "https://example.com"})
		if r.Error != "" {
			t.Fatal(r.Error)
		}
		t.Logf("%s: %s, %d backend calls, %d results", name, time.Since(start).Round(time.Millisecond), f.calls-before, len(r.Items))
	}
}
func TestSearchFindsOtherWebsites(t *testing.T) {
	f := searchFixture(1)
	s := service{backend: f}
	r := s.handle(context.Background(), request{Command: "list", URL: "https://different.test"})
	if r.Error != "" || len(r.Items) != 1 {
		t.Fatal("account-wide search must include other websites")
	}
}
func TestSearchBatchesUsernames(t *testing.T) {
	f := searchFixture(24)
	s := service{backend: f}
	r := s.handle(context.Background(), request{Command: "list", URL: "https://example.com"})
	if r.Error != "" || f.individual != 0 || f.batches != 1 || f.reads != 0 {
		t.Fatalf("search must batch usernames without reading passwords: individual=%d, batches=%d, reads=%d", f.individual, f.batches, f.reads)
	}
}
func TestSearchReusesIndex(t *testing.T) {
	f := searchFixture(1)
	s := service{backend: f}
	ctx := context.Background()
	s.handle(ctx, request{Command: "list", URL: "https://example.com"})
	calls := f.calls
	r := s.handle(ctx, request{Command: "list", URL: "https://different.test"})
	if r.Error != "" || len(r.Items) != 1 || f.calls != calls {
		t.Fatal("reopening must search the memory index without SDK round trips")
	}
}
func TestSearchFiltersBeforeResultLimit(t *testing.T) {
	f := searchFixture(200)
	s := service{backend: f}
	r := s.handle(context.Background(), searchRequest(`{"command":"list","url":"https://example.com","query":"Login 0199"}`))
	if r.Error != "" || len(r.Items) != 1 || r.Items[0].ID != "199" {
		t.Fatal("search must find items beyond the displayed result limit")
	}
}
func TestSearchWorksWithoutWebsite(t *testing.T) {
	f := searchFixture(1)
	s := service{backend: f}
	r := s.handle(context.Background(), request{Command: "list"})
	if r.Error != "" || len(r.Items) != 1 {
		t.Fatal("search should work on the browser home page")
	}
}

func TestSearchIncludesAllActiveCategories(t *testing.T) {
	f := searchFixture(1)
	f.records = append(f.records, op.ItemOverview{ID: "note", VaultID: "v", Title: "Passport backup", Category: op.ItemCategorySecureNote, State: op.ItemStateActive}, op.ItemOverview{ID: "old", VaultID: "v", Title: "Archived", Category: op.ItemCategoryLogin, State: op.ItemStateArchived})
	s := service{backend: f}
	r := s.handle(context.Background(), request{Command: "list"})
	if r.Error != "" || len(r.Items) != 2 {
		t.Fatal("all active categories must be searchable")
	}
}

func TestCrossSiteFillRequiresExplicitOverride(t *testing.T) {
	f := &fakeBackend{item: op.Item{Category: op.ItemCategoryLogin, Websites: []op.Website{{URL: "https://saved.test", AutofillBehavior: op.AutofillBehaviorExactDomain}}, Fields: []op.ItemField{{ID: "password", Value: "fixture"}}}}
	s := service{backend: f}
	ctx := context.Background()
	r := s.handle(ctx, request{Command: "get", URL: "https://destination.test", Vault: "v", Item: "i"})
	if r.Error != "site_mismatch" || r.Password != "" {
		t.Fatal("cross-site fill needs confirmation")
	}
	r = s.handle(ctx, searchRequest(`{"command":"get","url":"https://destination.test","vault":"v","item":"i","allowCrossSite":true}`))
	if r.Error != "" || r.Password != "fixture" {
		t.Fatal("explicit cross-site choice must fill")
	}
	for _, site := range []string{"http://destination.test", "file:///tmp/login", "javascript:void(0)"} {
		r = s.handle(ctx, request{Command: "get", URL: site, Vault: "v", Item: "i", AllowCrossSite: true})
		if r.Error != "unsafe_page" || r.Password != "" {
			t.Fatal("confirmation must not bypass origin safety")
		}
	}
	f.item.Category = op.ItemCategorySecureNote
	r = s.handle(ctx, request{Command: "get", URL: "https://destination.test", Vault: "v", Item: "i", AllowCrossSite: true})
	if r.Error == "" || r.Password != "" {
		t.Fatal("non-login items must never be filled")
	}
}

func TestSearchRanksCurrentSiteAndSearchesMetadata(t *testing.T) {
	f := searchFixture(3)
	f.records[0].Title = "Z Current site"
	f.records[1].Title = "A Other site"
	f.records[1].Websites = []op.Website{{URL: "https://elsewhere.test/login", AutofillBehavior: op.AutofillBehaviorExactDomain}}
	f.records[1].Tags = []string{"finance/team"}
	f.records[2].Websites[0].AutofillBehavior = op.AutofillBehaviorNever
	s := service{backend: f}
	ctx := context.Background()
	r := s.handle(ctx, request{Command: "list", URL: "https://example.com"})
	if r.Items[0].ID != "0" || !r.Items[0].MatchesSite || r.Items[1].MatchesSite || r.Items[2].MatchesSite {
		t.Fatal("only matching sites should rank first")
	}
	for _, query := range []string{"ELSEWHERE", "finance team", "work other", "user@example.com other"} {
		r = s.handle(ctx, request{Command: "list", Query: query})
		if len(r.Items) != 1 || r.Items[0].ID != "1" {
			t.Fatalf("search must include metadata: %s", query)
		}
	}
}
func TestSearchPagesWithoutTruncatingCatalog(t *testing.T) {
	f := searchFixture(83)
	s := service{backend: f}
	ctx := context.Background()
	seen := map[string]bool{}
	for _, offset := range []int{0, 40, 80} {
		r := s.handle(ctx, request{Command: "list", Offset: offset})
		if r.Total != 83 || r.Offset != offset || len(r.Items) > 40 {
			t.Fatal("wrong page boundaries")
		}
		for _, item := range r.Items {
			if seen[item.ID] {
				t.Fatal("duplicate across pages")
			}
			seen[item.ID] = true
		}
	}
	if len(seen) != 83 {
		t.Fatal("all items must be reachable")
	}
}
func TestSearchRefreshAndExpiryDiscardOldData(t *testing.T) {
	f := searchFixture(1)
	now := time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)
	s := service{backend: f, now: func() time.Time { return now }}
	ctx := context.Background()
	s.handle(ctx, request{Command: "list"})
	f.records[0].Title = "Renamed"
	if r := s.handle(ctx, request{Command: "list"}); r.Items[0].Title == "Renamed" {
		t.Fatal("fixture should still use cache")
	}
	if r := s.handle(ctx, request{Command: "list", Refresh: true}); r.Items[0].Title != "Renamed" {
		t.Fatal("explicit refresh must reload")
	}
	f.records[0].Title = "Expired"
	now = now.Add(indexLifetime)
	if r := s.handle(ctx, request{Command: "list"}); r.Items[0].Title != "Expired" {
		t.Fatal("expired index must reload")
	}
	f.listFailure = true
	if r := s.handle(ctx, request{Command: "list", Refresh: true}); r.Error != "access_failed" || len(r.Items) != 0 {
		t.Fatal("failed refresh must not serve stale metadata")
	}
	if r := s.handle(ctx, request{Command: "list"}); r.Error != "access_failed" {
		t.Fatal("failure must clear cache")
	}
}
func TestAccountSwitchDropsIndex(t *testing.T) {
	first := searchFixture(1)
	second := searchFixture(1)
	second.records[0].Title = "Second account"
	s := service{backend: first, connect: func(context.Context, string) (backend, error) { return second, nil }}
	ctx := context.Background()
	s.handle(ctx, request{Command: "list"})
	s.handle(ctx, request{Command: "connect", Account: "other"})
	if r := s.handle(ctx, request{Command: "list"}); len(r.Items) != 1 || r.Items[0].Title != "Second account" {
		t.Fatal("previous account metadata must never be reused")
	}
}
func TestCreateInvalidatesSearchEvenWhenUncertain(t *testing.T) {
	for _, uncertain := range []bool{false, true} {
		f := searchFixture(1)
		f.fail = uncertain
		s := service{backend: f}
		ctx := context.Background()
		s.handle(ctx, request{Command: "list"})
		before := f.calls
		s.handle(ctx, request{Command: "create", URL: "https://example.com", Vault: "v", Title: "Created", Password: "fixture"})
		s.handle(ctx, request{Command: "list"})
		if f.calls == before {
			t.Fatal("writes must invalidate the index")
		}
	}
}
func TestSearchDoesNotReadFieldsForOtherCategories(t *testing.T) {
	f := searchFixture(1)
	f.records[0].Category = op.ItemCategorySecureNote
	s := service{backend: f}
	r := s.handle(context.Background(), request{Command: "list"})
	if len(r.Items) != 1 || f.batches != 0 || f.reads != 0 || r.Items[0].Username != "" || r.Password != "" {
		t.Fatal("non-login search must use overview metadata only")
	}
}
