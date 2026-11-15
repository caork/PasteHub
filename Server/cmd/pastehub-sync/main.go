// Command pastehub-sync is the end-to-end encrypted relay for PasteHub clipboard sync.
//
//	pastehub-sync serve  -data DIR -addr 127.0.0.1:9021
//	pastehub-sync keygen -data DIR [-label NAME]   create a space and print its sync key once
//	pastehub-sync spaces -data DIR                 list spaces
//	pastehub-sync revoke -data DIR SPACE_ID        delete a space and all its data
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/caork/pastehub/server/internal/syncserver"
)

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	var err error
	switch cmd {
	case "serve":
		err = serve(args)
	case "keygen":
		err = keygen(args)
	case "spaces":
		err = spaces(args)
	case "revoke":
		err = revoke(args)
	case "version":
		fmt.Println(version)
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: pastehub-sync <serve|keygen|spaces|revoke|version> [flags]")
}

func dataFlag(fs *flag.FlagSet) *string {
	return fs.String("data", "/var/lib/pastehub-sync", "data directory")
}

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	data := dataFlag(fs)
	addr := fs.String("addr", "127.0.0.1:9021", "listen address")
	fs.Parse(args)

	store, err := syncserver.OpenStore(*data)
	if err != nil {
		return err
	}
	defer store.Close()

	logger := log.New(os.Stderr, "", log.LstdFlags)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           syncserver.NewServer(store, version, logger).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for {
			if err := store.Compact(ctx, syncserver.DefaultRetention, time.Now()); err != nil && ctx.Err() == nil {
				logger.Printf("compaction failed: %v", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()

	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()

	logger.Printf("pastehub-sync %s listening on %s", version, *addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func keygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	data := dataFlag(fs)
	label := fs.String("label", "", "human-readable label for this space")
	fs.Parse(args)

	store, err := syncserver.OpenStore(*data)
	if err != nil {
		return err
	}
	defer store.Close()

	key, master, err := syncserver.GenerateKey()
	if err != nil {
		return err
	}
	spaceID := syncserver.SpaceIDForKey(master)
	if err := store.CreateSpace(context.Background(), spaceID, *label); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "space %s created. The key below is shown once and is not stored on the server.\n", spaceID)
	fmt.Println(key)
	return nil
}

func spaces(args []string) error {
	fs := flag.NewFlagSet("spaces", flag.ExitOnError)
	data := dataFlag(fs)
	fs.Parse(args)

	store, err := syncserver.OpenStore(*data)
	if err != nil {
		return err
	}
	defer store.Close()
	list, err := store.ListSpaces(context.Background())
	if err != nil {
		return err
	}
	for _, sp := range list {
		fmt.Printf("%s\t%s\t%s\tblobs=%dB\thorizon=%d\n",
			sp.ID, sp.CreatedAt.Format(time.RFC3339), sp.Label, sp.BlobBytes, sp.HorizonSeq)
	}
	return nil
}

func revoke(args []string) error {
	fs := flag.NewFlagSet("revoke", flag.ExitOnError)
	data := dataFlag(fs)
	fs.Parse(args)
	if fs.NArg() != 1 {
		return errors.New("revoke needs exactly one SPACE_ID")
	}
	store, err := syncserver.OpenStore(*data)
	if err != nil {
		return err
	}
	defer store.Close()
	return store.DeleteSpace(context.Background(), fs.Arg(0))
}
