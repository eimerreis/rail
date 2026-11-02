package main

import (
	"context"
	"errors"
	op "github.com/1password/onepassword-sdk-go"
	"testing"
)

type fakeBackend struct {
	reads, creates int
	item           op.Item
	created        op.ItemCreateParams
	fail           bool
}

func (f *fakeBackend) vaults(context.Context) ([]op.VaultOverview, error) {
	return []op.VaultOverview{{ID: "v", Title: "Work"}}, nil
}
func (f *fakeBackend) items(context.Context, string) ([]op.ItemOverview, error) {
	return []op.ItemOverview{{ID: "i", VaultID: "v", Title: "Example", Category: op.ItemCategoryLogin, State: op.ItemStateActive, Websites: []op.Website{{URL: "https://example.com", AutofillBehavior: op.AutofillBehaviorExactDomain}}}}, nil
}
func (f *fakeBackend) get(context.Context, string, string) (op.Item, error) {
	f.reads++
	return f.item, nil
}
func (f *fakeBackend) usernames(_ context.Context, items []searchItem) (map[string]string, error) {
	names := map[string]string{}
	for _, item := range items {
		names[item.Vault+"/"+item.ID] = "user@example.com"
	}
	return names, nil
}
func (f *fakeBackend) create(_ context.Context, p op.ItemCreateParams) (op.Item, error) {
	f.creates++
	f.created = p
	if f.fail {
		return op.Item{}, errors.New("secret error")
	}
	return op.Item{ID: "new"}, nil
}

func TestListDoesNotReadPasswordsAndSelectionRevalidates(t *testing.T) {
	f := &fakeBackend{item: op.Item{Category: op.ItemCategoryLogin, Websites: []op.Website{{URL: "https://different.test", AutofillBehavior: op.AutofillBehaviorExactDomain}}, Fields: []op.ItemField{{ID: "password", Value: "secret"}}}}
	s := service{backend: f}
	ctx := context.Background()
	r := s.handle(ctx, request{Command: "list", URL: "https://example.com/login"})
	if r.Error != "" || len(r.Items) != 1 || f.reads != 0 {
		t.Fatal("listing must use metadata only")
	}
	r = s.handle(ctx, request{Command: "get", URL: "https://example.com/login", Vault: "v", Item: "i"})
	if r.Error == "" || r.Password != "" {
		t.Fatal("changed item website must refuse filling")
	}
}
func TestCreateValidatesAndSavesTypedLogin(t *testing.T) {
	f := &fakeBackend{}
	s := service{backend: f}
	ctx := context.Background()
	r := s.handle(ctx, request{Command: "create", URL: "https://example.com/signup?token=private", Vault: "v", Title: "Example", Username: "user", Password: "test-only-password"})
	if r.Error != "" || !r.Saved || f.creates != 1 {
		t.Fatal("valid creation failed")
	}
	p := f.created
	if p.Category != op.ItemCategoryLogin || p.Websites[0].URL != "https://example.com" || p.Websites[0].AutofillBehavior != op.AutofillBehaviorExactDomain || p.Fields[1].FieldType != op.ItemFieldTypeConcealed {
		t.Fatal("wrong item semantics")
	}
	for _, u := range []string{"http://example.com", "javascript:alert(1)"} {
		if r = s.handle(ctx, request{Command: "create", URL: u, Vault: "v", Title: "Example", Password: "test"}); r.Error == "" || f.creates != 1 {
			t.Fatal("unsafe destination reached backend")
		}
	}
	f.fail = true
	r = s.handle(ctx, request{Command: "create", URL: "https://example.com", Vault: "v", Title: "Example", Password: "test"})
	if r.Error != "save_uncertain" || r.Saved || r.Password != "" {
		t.Fatal("save must not claim success or leak SDK errors")
	}
}
func TestGeneratorRecipeBounds(t *testing.T) {
	s := service{}
	for _, n := range []int{-1, 0, 7, 101} {
		if r := s.handle(context.Background(), request{Command: "generate", Length: n}); r.Error != "invalid_recipe" {
			t.Fatal("invalid length accepted")
		}
	}
	r := s.handle(context.Background(), request{Command: "generate", Length: 24, Symbols: true})
	if r.Error != "" || len(r.Password) != 24 {
		t.Fatal("SDK did not generate requested password")
	}
}
