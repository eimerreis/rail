package main

import (
	"context"
	op "github.com/1password/onepassword-sdk-go"
	"net/url"
	"strings"
	"time"
)

type request struct {
	ID             string `json:"id"`
	Command        string `json:"command"`
	Account        string `json:"account"`
	URL            string `json:"url"`
	Vault          string `json:"vault"`
	Item           string `json:"item"`
	Title          string `json:"title"`
	Username       string `json:"username"`
	Password       string `json:"password"`
	Length         int    `json:"length"`
	Symbols        bool   `json:"symbols"`
	Query          string `json:"query"`
	Offset         int    `json:"offset"`
	Refresh        bool   `json:"refresh"`
	AllowCrossSite bool   `json:"allowCrossSite"`
}
type vault struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}
type searchItem struct {
	ID          string   `json:"id"`
	Vault       string   `json:"vault"`
	Title       string   `json:"title"`
	Username    string   `json:"username"`
	VaultTitle  string   `json:"vaultTitle"`
	Websites    []string `json:"websites"`
	MatchesSite bool     `json:"matchesSite"`
	Category    string   `json:"category"`
}
type response struct {
	ID          string       `json:"id"`
	Error       string       `json:"error,omitempty"`
	Vaults      []vault      `json:"vaults,omitempty"`
	Items       []searchItem `json:"items,omitempty"`
	Username    string       `json:"username,omitempty"`
	Password    string       `json:"password,omitempty"`
	Saved       bool         `json:"saved,omitempty"`
	Total       int          `json:"total"`
	Offset      int          `json:"offset"`
	Link        string       `json:"link,omitempty"`
	AccountLink string       `json:"accountLink,omitempty"`
}

// The adapter deliberately exposes no update, delete or arbitrary secret API.
type backend interface {
	vaults(context.Context) ([]op.VaultOverview, error)
	items(context.Context, string) ([]op.ItemOverview, error)
	usernames(context.Context, []searchItem) (map[string]string, error)
	get(context.Context, string, string) (op.Item, error)
	create(context.Context, op.ItemCreateParams) (op.Item, error)
}
type sdkBackend struct{ client *op.Client }

func (b sdkBackend) vaults(c context.Context) ([]op.VaultOverview, error) {
	return b.client.Vaults().List(c)
}
func (b sdkBackend) items(c context.Context, v string) ([]op.ItemOverview, error) {
	return b.client.Items().List(c, v)
}
func (b sdkBackend) usernames(c context.Context, items []searchItem) (map[string]string, error) {
	refs := make([]string, 0, len(items))
	for _, item := range items {
		refs = append(refs, "op://"+url.PathEscape(item.Vault)+"/"+url.PathEscape(item.ID)+"/username")
	}
	result, err := b.client.Secrets().ResolveAll(c, refs)
	if err != nil {
		return nil, err
	}
	names := make(map[string]string, len(items))
	for index, ref := range refs {
		if value := result.IndividualResponses[ref]; value.Content != nil && value.Error == nil {
			names[items[index].Vault+"/"+items[index].ID] = value.Content.Secret
		}
	}
	return names, nil
}
func (b sdkBackend) get(c context.Context, v, i string) (op.Item, error) {
	return b.client.Items().Get(c, v, i)
}
func (b sdkBackend) create(c context.Context, p op.ItemCreateParams) (op.Item, error) {
	return b.client.Items().Create(c, p)
}

type service struct {
	backend     backend
	connect     func(context.Context, string) (backend, error)
	index       []indexedItem
	indexVaults []vault
	indexedAt   time.Time
	now         func() time.Time
}

func matches(websites []op.Website, destination string) bool {
	for _, w := range websites {
		if websiteAllows(w.URL, destination, string(w.AutofillBehavior)) {
			return true
		}
	}
	return false
}
func short(s string) string {
	r := []rune(s)
	if len(r) > 256 {
		return string(r[:256])
	}
	return s
}
func (s *service) handle(ctx context.Context, r request) response {
	out := response{ID: r.ID}
	fail := func(code string) response { return response{ID: r.ID, Error: code} }
	if r.Command == "generate" {
		if r.Length < 8 || r.Length > 100 {
			return fail("invalid_recipe")
		}
		value, err := op.Secrets.GeneratePassword(ctx, op.NewPasswordRecipeTypeVariantRandom(&op.PasswordRecipeRandomInner{Length: uint32(r.Length), IncludeDigits: true, IncludeSymbols: r.Symbols}))
		if err != nil {
			return fail("generation_failed")
		}
		out.Password = value.Password
		return out
	}
	if r.Command == "connect" {
		if len(r.Account) == 0 || len(r.Account) > 256 {
			return fail("account_required")
		}
		s.backend = nil
		s.clearIndex()
		if s.connect != nil {
			b, err := s.connect(ctx, r.Account)
			if err != nil {
				return fail("connection_failed")
			}
			s.backend = b
		} else {
			client, err := op.NewClient(ctx, op.WithDesktopAppIntegration(r.Account), op.WithIntegrationInfo("Rail", "0.1.0"))
			if err != nil {
				return fail("connection_failed")
			}
			s.backend = sdkBackend{client}
		}
	}
	if s.backend == nil {
		return fail("not_connected")
	}
	switch r.Command {
	case "item-link":
		return itemLink(r)
	case "list":
		return s.search(ctx, r)
	case "connect":
		vaults, err := s.backend.vaults(ctx)
		if err != nil {
			return fail("access_failed")
		}
		if len(vaults) > 256 {
			return fail("too_many_vaults")
		}
		for _, v := range vaults {
			out.Vaults = append(out.Vaults, vault{v.ID, short(v.Title)})
		}
	case "get":
		if _, ok := origin(r.URL); !ok {
			return fail("unsafe_page")
		}
		if r.Vault == "" || r.Item == "" {
			return fail("invalid_item")
		}
		item, err := s.backend.get(ctx, r.Vault, r.Item)
		if err != nil {
			s.clearIndex()
			return fail("access_failed")
		}
		if item.Category != op.ItemCategoryLogin || (!matches(item.Websites, r.URL) && !r.AllowCrossSite) {
			return fail("site_mismatch")
		}
		for _, f := range item.Fields {
			if f.ID == "username" {
				out.Username = f.Value
			}
			if f.ID == "password" {
				out.Password = f.Value
			}
		}
		if out.Username == "" && out.Password == "" {
			return fail("empty_login")
		}
	case "create":
		u, ok := origin(r.URL)
		if !ok {
			return fail("unsafe_page")
		}
		if r.Vault == "" || strings.TrimSpace(r.Title) == "" || len(r.Title) > 256 || r.Password == "" || len(r.Password) > 4096 || len(r.Username) > 1024 {
			return fail("invalid_login")
		}
		_, err := s.backend.create(ctx, op.ItemCreateParams{Category: op.ItemCategoryLogin, VaultID: r.Vault, Title: r.Title,
			Fields:   []op.ItemField{{ID: "username", Title: "username", FieldType: op.ItemFieldTypeText, Value: r.Username}, {ID: "password", Title: "password", FieldType: op.ItemFieldTypeConcealed, Value: r.Password}},
			Websites: []op.Website{{URL: u.String(), AutofillBehavior: op.AutofillBehaviorExactDomain}}})
		s.clearIndex()
		// A transport failure may happen after the write committed. Never retry automatically.
		if err != nil {
			return fail("save_uncertain")
		}
		out.Saved = true
	default:
		return fail("unknown_command")
	}
	return out
}
