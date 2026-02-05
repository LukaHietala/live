package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
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

func TestValidHandshake(t *testing.T) {
	_, addr := startTestServer()

	conn, _ := net.Dial("tcp", addr)
	defer conn.Close()
	fmt.Fprintln(conn, `{"event": "handshake", "name": "Kiltti pomeranian"}`)

	reply, _ := bufio.NewReader(conn).ReadString('\n')
	if !strings.Contains(reply, "user_joined") {
		t.Fatalf("Expected user_joined event, got: %s", reply)
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

func TestHostMigration(t *testing.T) {
	server, addr := startTestServer()

	// First client (should be host)
	c1, _ := net.Dial("tcp", addr)
	fmt.Fprintln(c1, `{"event": "handshake", "name": "host"}`)

	// Second client
	c2, _ := net.Dial("tcp", addr)
	fmt.Fprintln(c2, `{"event": "handshake", "name": "koira"}`)
	time.Sleep(50 * time.Millisecond)

	// Disconnect first host
	c1.Close()
	time.Sleep(50 * time.Millisecond)

	// Verify that second client is the host
	done := make(chan bool)
	server.actions <- func() {
		host := server.getHost()
		if host != nil && host.Name == "koira" && host.IsHost {
			done <- true
		} else {
			done <- false
		}
	}

	if !<-done {
		t.Error("Host crown was not passed to the second client correctly")
	}
}

func TestRequestTimeoutCleanup(t *testing.T) {
	server, addr := startTestServer()

	conn, _ := net.Dial("tcp", addr)
	fmt.Fprintln(conn, `{"event": "handshake", "name": "requester"}`)
	time.Sleep(20 * time.Millisecond)

	fmt.Fprintln(conn, `{"event": "request_files"}`)
	time.Sleep(100 * time.Millisecond)

	// Make sure that request was created
	server.actions <- func() {
		if len(server.PendingRequests) == 0 {
			t.Errorf("Request was never registered")
		}
	}

	time.Sleep(RequestTimeout + 50*time.Millisecond)

	// Make sure that timeout clears the request
	server.actions <- func() {
		if len(server.PendingRequests) != 0 {
			t.Errorf("Pending request was not cleaned up after timeout")
		}
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

	// Print messages per second
	duration := b.Elapsed()
	if duration > 0 {
		opsPerSec := float64(b.N) / duration.Seconds()
		b.ReportMetric(opsPerSec, "msg/sec")
	}

	for _, c := range conns {
		c.Close()
	}
}
