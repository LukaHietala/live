package main

import (
	"bufio"
	"fmt"
	"net"
	"testing"
	"time"
)

func startServer() string {
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() {
		for {
			conn, _ := listener.Accept()
			go handleConnection(conn)
		}
	}()
	return listener.Addr().String()
}

func TestBasics(t *testing.T) {
	addr := startServer()

	// Test valid handshake
	t.Run("ValidHandshake", func(t *testing.T) {
		conn, _ := net.Dial("tcp", addr)
		fmt.Fprintln(conn, `{"event": "handshake", "name": "Kiltti pomeranian"}`)

		reply, _ := bufio.NewReader(conn).ReadString('\n')
		if reply == "" {
			t.Fatal("No response")
		}
	})

	// Test fragmented packets
	t.Run("Fragmented", func(t *testing.T) {
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
	})

	// Bad disconnect
	t.Run("Disconnect", func(t *testing.T) {
		conn, _ := net.Dial("tcp", addr)
		fmt.Fprintln(conn, `{"event": "handshake", "name": "Karkaileva pomeranian"}`)

		time.Sleep(10 * time.Millisecond)
		// Hard close
		conn.Close()
		time.Sleep(10 * time.Millisecond)

		server.mu.Lock()
		defer server.mu.Unlock()
		if len(server.Clients) > 0 {
			// Make sure that client doesn't linger
			for _, c := range server.Clients {
				if c.Name == "Karkaileva pomeranian" {
					t.Error("Client was not removed")
				}
			}
		}
	})
}

func TestLimits(t *testing.T) {
	addr := startServer()

	t.Run("MessageTooBig", func(t *testing.T) {
		conn, _ := net.Dial("tcp", addr)
		// Send a message larger than MaxBufferSize
		bigMsg := make([]byte, MaxBufferSize+1024)
		for i := range bigMsg {
			bigMsg[i] = 'a'
		}
		fmt.Fprintln(conn, string(bigMsg))

		time.Sleep(50 * time.Millisecond)
		// The scanner should fail and the server should drop the client
		server.mu.Lock()
		count := len(server.Clients)
		server.mu.Unlock()

		if count > 0 {
			t.Error("Server did not drop client for exceeding MaxBufferSize")
		}
	})

	t.Run("HostTimeout", func(t *testing.T) {
		conn, _ := net.Dial("tcp", addr)
		fmt.Fprintln(conn, `{"event": "handshake", "name": "host"}`)

		// Second client makes a request
		conn2, _ := net.Dial("tcp", addr)
		fmt.Fprintln(conn2, `{"event": "handshake", "name": "client"}`)
		fmt.Fprintln(conn2, `{"event": "request"}`) // Host won't reply

		// Don't actually test timeout, only make sure that it went to pending requests
		// Actual thing would slowdown tests
		time.Sleep(100 * time.Millisecond)

		server.mu.Lock()
		reqCount := len(server.PendingRequests)
		server.mu.Unlock()

		if reqCount == 0 {
			t.Error("Request was not added to PendingRequests")
		}
	})
}
