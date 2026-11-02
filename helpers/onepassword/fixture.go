package main

// An explicit --fixture-origin flag selects this disposable in-memory backend.
// It can only target loopback HTTP and never constructs an SDK account client.
import (
	"context"
	"errors"
	"fmt"
	op "github.com/1password/onepassword-sdk-go"
	"time"
)

type fixtureBackend struct{ records []op.Item }

func newFixture(site string) *fixtureBackend {
	f := &fixtureBackend{records: []op.Item{{ID: "demo", VaultID: "fixture", Title: "Demo account", Category: op.ItemCategoryLogin,
		Fields:   []op.ItemField{{ID: "username", Value: "demo@example.test"}, {ID: "password", Value: "Rail-disposable-test-123!"}},
		Websites: []op.Website{{URL: site, AutofillBehavior: op.AutofillBehaviorExactDomain}}}}}
	f.records = append(f.records, op.Item{ID: "other", VaultID: "fixture", Title: "Elsewhere account", Category: op.ItemCategoryLogin, Fields: []op.ItemField{{ID: "username", Value: "elsewhere@example.test"}, {ID: "password", Value: "Rail-other-fixture-123!"}}, Websites: []op.Website{{URL: "https://elsewhere.example", AutofillBehavior: op.AutofillBehaviorExactDomain}}}, op.Item{ID: "note", VaultID: "fixture", Title: "Passport backup", Category: op.ItemCategorySecureNote})
	for i := 0; i < 80; i++ {
		f.records = append(f.records, op.Item{ID: fmt.Sprintf("reference-%d", i), VaultID: "fixture", Title: fmt.Sprintf("Reference %03d", i), Category: op.ItemCategoryDocument})
	}
	return f
}
func (f *fixtureBackend) vaults(context.Context) ([]op.VaultOverview, error) {
	return []op.VaultOverview{{ID: "fixture", Title: "Disposable test vault"}}, nil
}
func (f *fixtureBackend) items(ctx context.Context, _ string) ([]op.ItemOverview, error) {
	// Enough time to type while a cold/explicit refresh is pending.
	select {
	case <-time.After(500 * time.Millisecond):
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	out := []op.ItemOverview{}
	for _, r := range f.records {
		out = append(out, op.ItemOverview{ID: r.ID, VaultID: r.VaultID, Title: r.Title, Category: r.Category, State: op.ItemStateActive, Websites: r.Websites})
	}
	return out, nil
}
func (f *fixtureBackend) get(ctx context.Context, v, id string) (op.Item, error) {
	// Metadata reads stay immediate. Explicit secret reads leave enough time for
	// the native harness to navigate while the helper request is still pending.
	select {
	case <-time.After(time.Second):
	case <-ctx.Done():
		return op.Item{}, ctx.Err()
	}
	return f.lookup(v, id)
}
func (f *fixtureBackend) lookup(v, id string) (op.Item, error) {
	for _, r := range f.records {
		if r.ID == id && r.VaultID == v {
			return r, nil
		}
	}
	return op.Item{}, errors.New("missing fixture")
}
func (f *fixtureBackend) usernames(_ context.Context, items []searchItem) (map[string]string, error) {
	names := map[string]string{}
	for _, i := range items {
		item, err := f.lookup(i.Vault, i.ID)
		if err != nil {
			return nil, err
		}
		for _, field := range item.Fields {
			if field.ID == "username" {
				names[i.Vault+"/"+i.ID] = field.Value
			}
		}
	}
	return names, nil
}
func (f *fixtureBackend) create(_ context.Context, p op.ItemCreateParams) (op.Item, error) {
	if p.VaultID != "fixture" {
		return op.Item{}, errors.New("invalid fixture vault")
	}
	item := op.Item{ID: fmt.Sprintf("created-%d", len(f.records)), VaultID: p.VaultID, Title: p.Title, Category: p.Category, Fields: p.Fields, Websites: p.Websites}
	f.records = append(f.records, item)
	if p.Title == "Uncertain fixture" {
		return op.Item{}, errors.New("fixture committed before transport failure")
	}
	return item, nil
}
