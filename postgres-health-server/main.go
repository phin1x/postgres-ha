package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v4"
)

func main() {
	ctx, cancel := context.WithCancel(context.Background())

	// handle graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM)
	go func() {
		<-stop
		cancel()
	}()

	connectionUri, found := os.LookupEnv("DATABASE_URL")
	if !found {
		_, _ = fmt.Fprintln(os.Stderr, "env var DATABASE_URL is not set")
		os.Exit(1)
	}

	var conn *pgx.Conn

	mux := http.NewServeMux()
	// postgres health handler, we query the recovery state
	// true: instance is a slave -> http 206 partial content
	// false: instance is the primary -> http 200 ok
	// error: instance is down -> http 503 service unavailable
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if conn == nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = fmt.Fprintf(w, "down")
			return
		}

		var inRecovery bool
		if err := conn.QueryRow(ctx, "SELECT pg_is_in_recovery()").Scan(&inRecovery); err != nil {
			_, _ = fmt.Fprintf(os.Stderr, "failed to query recovery state: %v\n", err)

			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = fmt.Fprintf(w, "down")
			return
		}

		if inRecovery {
			w.WriteHeader(http.StatusPartialContent)
			_, _ = fmt.Fprintf(w, "slave")
			return
		}

		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintf(w, "master")
	})
	// health endpoint for the http server
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintf(w, "ok")
	})

	// setup http server
	srv := &http.Server{
		Addr:    ":9201",
		Handler: mux,
	}

	// start http server
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			_, _ = fmt.Fprintf(os.Stderr, "Unable to listen on port 9201: %v\n", err)
			os.Exit(1)
		}
	}()

	_, _ = fmt.Fprintln(os.Stdout, "listening on :9201")

	// open connection
	var err error
	// retry until we successful connect to the database
	for {
		conn, err = pgx.Connect(ctx, connectionUri)
		if err == nil {
			// no error, connection established
			break
		}

		// error -> log and retry in 2 seconds
		_, _ = fmt.Fprintf(os.Stderr, "Unable to connect to database: %v\n", err)
		time.Sleep(time.Second * 2)
	}
	defer conn.Close(ctx)

	_, _ = fmt.Fprintln(os.Stdout, "database connection established")

	// wait for a stop signal
	<-ctx.Done()

	_, _ = fmt.Fprintln(os.Stdout, "stopping server")

	// set stop timeout to 10 seconds
	ctxShutdown, cancelShutdown := context.WithTimeout(context.Background(), time.Second*10)
	defer cancelShutdown()

	// stop server
	if err := srv.Shutdown(ctxShutdown); err != nil && err != http.ErrServerClosed {
		_, _ = fmt.Fprintf(os.Stderr, "server shutdown failed: %v\n", err)
	}

	_, _ = fmt.Fprintln(os.Stdout, "server stopped")
}
