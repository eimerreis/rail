package main

import (
	"context"
	op "github.com/1password/onepassword-sdk-go"
	"sort"
	"strings"
	"time"
)

// Only search metadata and usernames are cached; passwords always require a
// fresh SDK read. The process owns the index and disconnect destroys it.
const indexLifetime = 2 * time.Minute
const searchPageSize = 40
const usernameBatchSize = 100

type indexedItem struct {
	item     searchItem
	websites []op.Website
	text     string
}

func (s *service) clearIndex() { s.index = nil; s.indexVaults = nil; s.indexedAt = time.Time{} }
func (s *service) search(ctx context.Context, r request) response {
	fail := func(code string) response { s.clearIndex(); return response{ID: r.ID, Error: code} }
	now := time.Now()
	if s.now != nil {
		now = s.now()
	}
	if r.Refresh || s.indexedAt.IsZero() || now.Sub(s.indexedAt) >= indexLifetime {
		// Replace the index atomically. Failed/partial reads never retain an old
		// catalog after an access or account change.
		s.clearIndex()
		vaults, err := s.backend.vaults(ctx)
		if err != nil {
			return fail("access_failed")
		}
		if len(vaults) > 256 {
			return fail("too_many_vaults")
		}
		catalog := []indexedItem{}
		for _, v := range vaults {
			s.indexVaults = append(s.indexVaults, vault{ID: v.ID, Title: short(v.Title)})
			items, err := s.backend.items(ctx, v.ID)
			if err != nil {
				return fail("access_failed")
			}
			for _, i := range items {
				if i.State != op.ItemStateActive {
					continue
				}
				entry := indexedItem{item: searchItem{ID: i.ID, Vault: v.ID, Title: short(i.Title), VaultTitle: short(v.Title), Category: string(i.Category)}, websites: i.Websites}
				// Search the full title, tags and saved websites, but return only
				// bounded display metadata through the private pipe.
				entry.text = i.Title + " " + v.Title + " " + string(i.Category) + " " + strings.Join(i.Tags, " ")
				for _, w := range i.Websites {
					entry.text += " " + w.URL
					if u, ok := origin(w.URL); ok && len(entry.item.Websites) < 8 {
						entry.item.Websites = append(entry.item.Websites, short(u.String()))
					}
				}
				catalog = append(catalog, entry)
			}
		}
		for start := 0; start < len(catalog); start += usernameBatchSize {
			end := min(start+usernameBatchSize, len(catalog))
			batch := make([]searchItem, 0, end-start)
			for _, entry := range catalog[start:end] {
				if entry.item.Category == string(op.ItemCategoryLogin) {
					batch = append(batch, entry.item)
				}
			}
			names := map[string]string{}
			if len(batch) > 0 {
				names, err = s.backend.usernames(ctx, batch)
				if err != nil {
					return fail("access_failed")
				}
			}
			for i := start; i < end; i++ {
				entry := &catalog[i]
				name := names[entry.item.Vault+"/"+entry.item.ID]
				entry.item.Username = short(name)
				entry.text = strings.ToLower(entry.text + " " + name)
			}
		}
		s.index = catalog
		s.indexedAt = now
	}
	terms := strings.Fields(strings.ToLower(r.Query))
	found := []searchItem{}
	for _, entry := range s.index {
		include := true
		for _, term := range terms {
			if !strings.Contains(entry.text, term) {
				include = false
				break
			}
		}
		if include {
			item := entry.item
			item.MatchesSite = item.Category == string(op.ItemCategoryLogin) && matches(entry.websites, r.URL)
			found = append(found, item)
		}
	}
	sort.SliceStable(found, func(i, j int) bool {
		a, b := found[i], found[j]
		if a.MatchesSite != b.MatchesSite {
			return a.MatchesSite
		}
		if strings.ToLower(a.Title) != strings.ToLower(b.Title) {
			return strings.ToLower(a.Title) < strings.ToLower(b.Title)
		}
		if a.Vault != b.Vault {
			return a.Vault < b.Vault
		}
		return a.ID < b.ID
	})
	offset := max(0, r.Offset)
	if offset >= len(found) {
		offset = max(0, ((len(found)-1)/searchPageSize)*searchPageSize)
	}
	return response{ID: r.ID, Vaults: s.indexVaults, Items: found[offset:min(offset+searchPageSize, len(found))], Total: len(found), Offset: offset}
}
