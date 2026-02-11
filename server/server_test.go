package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func startTestServer() (*Server, string) {
	server := NewServer()
	go server.run()

	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go server.handleConnection(conn)
		}
	}()
	return server, listener.Addr().String()
}

func TestMain(m *testing.M) {
	// Discard logs
	log.SetOutput(io.Discard)
	os.Exit(m.Run())
}

func TestValidHandshake(t *testing.T) {
	_, addr := startTestServer()

	conn, _ := net.Dial("tcp", addr)
	defer conn.Close()
	fmt.Fprintln(conn, `{"event": "handshake", "name": "Kiltti pomeranian"}`)

	reply, _ := bufio.NewReader(conn).ReadString('\n')
	if !strings.Contains(reply, "handshake_response") {
		t.Fatalf("Expected handshake_response, got: %s", reply)
	}
}

func TestDisconnect(t *testing.T) {
	server, addr := startTestServer()

	conn, _ := net.Dial("tcp", addr)
	fmt.Fprintln(conn, `{"event": "handshake", "name": "Karkaileva kissa"}`)
	time.Sleep(20 * time.Millisecond)
	conn.Close()
	time.Sleep(20 * time.Millisecond)

	done := make(chan bool)
	server.actions <- func() {
		if len(server.Clients) == 0 {
			done <- true
		} else {
			done <- false
		}
	}
	if !<-done {
		t.Error("Client was not removed from server after disconnect")
	}
}

func TestFragmentation(t *testing.T) {
	_, addr := startTestServer()

	conn, _ := net.Dial("tcp", addr)
	// Send half
	fmt.Fprint(conn, `{"event": "hand`)
	time.Sleep(50 * time.Millisecond)
	// Send the other half with newline
	fmt.Fprintln(conn, `shake", "name": "Fragmentoitu pomeranian"}`)

	reply, _ := bufio.NewReader(conn).ReadString('\n')
	if reply == "" {
		t.Error("Unable to handle fragmented message")
	}
}

func TestMessageLimits(t *testing.T) {
	server, addr := startTestServer()

	conn, _ := net.Dial("tcp", addr)
	defer conn.Close()

	// Create a message slightly larger than the limit
	bigMsg := make([]byte, MaxBufferSize+1024)
	for i := range bigMsg {
		bigMsg[i] = 'a'
	}
	fmt.Fprintln(conn, string(bigMsg))

	time.Sleep(50 * time.Millisecond)

	done := make(chan int)
	server.actions <- func() {
		done <- len(server.Clients)
	}
	if <-done > 0 {
		t.Error("Server did not drop client for exceeding MaxBufferSize")
	}
}

func TestHostClaiming(t *testing.T) {
	server, addr := startTestServer()

	// First client claims host
	c1, _ := net.Dial("tcp", addr)
	fmt.Fprintln(c1, `{"event": "handshake", "name": "host", "host": true}`)
	bufio.NewReader(c1).ReadString('\n') // Wait for response

	// Verify c1 is host
	done := make(chan bool)
	server.actions <- func() {
		if server.Host != nil && server.Host.Name == "host" && server.Host.IsHost {
			done <- true
		} else {
			done <- false
		}
	}
	if !<-done {
		t.Fatal("First client failed to claim host")
	}

	// Second client tries to claim host
	c2, _ := net.Dial("tcp", addr)
	fmt.Fprintln(c2, `{"event": "handshake", "name": "roisto", "host": true}`)
	bufio.NewReader(c2).ReadString('\n')

	// Verify c1 is still host (c2 failed)
	server.actions <- func() {
		if server.Host != nil && server.Host.Name == "host" {
			done <- true
		} else {
			done <- false
		}
	}

	if !<-done {
		t.Error("Second client stole host status, but shouldn't have")
	}
}

func TestRequestTimeoutCleanup(t *testing.T) {
	server, addr := startTestServer()

	// Join as host
	h, _ := net.Dial("tcp", addr)
	fmt.Fprintln(h, `{"event": "handshake", "name": "host", "host": true}`)
	bufio.NewReader(h).ReadString('\n') // clear buffer

	// Client that sends request
	conn, _ := net.Dial("tcp", addr)
	fmt.Fprintln(conn, `{"event": "handshake", "name": "requester"}`)
	bufio.NewReader(conn).ReadString('\n') // clear buffer

	// Send request
	fmt.Fprintln(conn, `{"event": "request_files"}`)
	time.Sleep(100 * time.Millisecond)

	// Make sure that request was created
	done := make(chan bool)
	server.actions <- func() {
		if len(server.PendingRequests) > 0 {
			done <- true
		} else {
			done <- false
		}
	}
	if !<-done {
		t.Errorf("Request was never registered (or rejected immediately)")
	}

	// Wait for timeout
	time.Sleep(RequestTimeout + 50*time.Millisecond)

	// Make sure that timeout clears the request
	server.actions <- func() {
		if len(server.PendingRequests) == 0 {
			done <- true
		} else {
			done <- false
		}
	}
	if !<-done {
		t.Errorf("Pending request was not cleaned up after timeout")
	}
}

func TestUnauthorizedAccess(t *testing.T) {
	_, addr := startTestServer()
	conn, _ := net.Dial("tcp", addr)
	defer conn.Close()

	// Try to move cursor WITHOUT handshake
	fmt.Fprintln(conn, `{"event": "cursor_move", "position": [10,10]}`)

	reply, _ := bufio.NewReader(conn).ReadString('\n')
	if !strings.Contains(reply, "Set name first!") {
		t.Fatalf("Server allowed message before handshake: %s", reply)
	}
}

func BenchmarkServerSingle(b *testing.B) {
	_, addr := startTestServer()
	conn, _ := net.Dial("tcp", addr)
	defer conn.Close()

	fmt.Fprintln(conn, `{"event": "handshake", "name": "benchmark"}`)
	msg := []byte(`{"event": "cursor_move", "position": [10,10]}` + "\n")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := conn.Write(msg)
		if err != nil {
			b.Fatal(err)
		}
	}

	duration := b.Elapsed()
	if duration > 0 {
		opsPerSec := float64(b.N) / duration.Seconds()
		b.ReportMetric(opsPerSec, "msg/sec")
	}
}

func BenchmarkServerMultiClient(b *testing.B) {
	_, addr := startTestServer()
	numClients := 10

	conns := make([]net.Conn, numClients)
	for i := range conns {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			b.Fatalf("failed to dial: %v", err)
		}
		// Standard clients (no host flag)
		fmt.Fprintf(c, `{"event": "handshake", "name": "hauva-%d"}`+"\n", i)
		conns[i] = c

		// Discard stream to keep buffer empty
		go io.Copy(io.Discard, c)
	}

	msg := []byte(`{"event": "cursor_move", "position": [10,10]}` + "\n")

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		id := 0
		for pb.Next() {
			conns[id%numClients].Write(msg)
			id++
		}
	})
	b.StopTimer()

	duration := b.Elapsed()
	if duration > 0 {
		opsPerSec := float64(b.N) / duration.Seconds()
		b.ReportMetric(opsPerSec, "msg/sec")
	}

	for _, c := range conns {
		c.Close()
	}
}
