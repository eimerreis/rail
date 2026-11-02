// Rail owns the pipes. This process exposes no network listener and writes no
// credentials to disk. stdout is exclusively the bounded request protocol.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"os"
	"time"
)

func main() {
	// Do not let an SDK panic dump credential-bearing Go values to stderr.
	defer func() {
		if recover() != nil {
			os.Exit(1)
		}
	}()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 65536)
	writer := bufio.NewWriter(os.Stdout)
	s := service{}
	fixtureURL := flag.String("fixture-origin", "", "loopback-only disposable test backend")
	flag.Parse()
	if *fixtureURL != "" {
		u, ok := origin(*fixtureURL)
		if !ok || u.Scheme != "http" {
			return
		}
		fixture := newFixture(u.String())
		s.connect = func(context.Context, string) (backend, error) { return fixture, nil }
	}
	for scanner.Scan() {
		var r request
		if json.Unmarshal(scanner.Bytes(), &r) != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		out := s.handle(ctx, r)
		cancel()
		data, err := json.Marshal(out)
		if err != nil || len(data) > 1024*1024 {
			return
		}
		if _, err = writer.Write(append(data, '\n')); err != nil {
			return
		}
		if writer.Flush() != nil {
			return
		}
	}
}
