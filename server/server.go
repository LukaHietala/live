package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

const (
	// 5 seconds to respond to request
	RequestTimeout = 5 * time.Second
	// 5MB hard file size limit
	MaxBufferSize = 5 * 1024 * 1024
)

type Client struct {
	Conn   net.Conn
	ID     int
	Name   string
	IsHost bool
	// Channel buffer for messages, ONLY WRITE TO THIS
	Send chan []byte
	// Signal channel for writer (signals close)
	Done chan struct{}
}

type PendingRequest struct {
	ClientID  int
	RequestID int
	Timer     *time.Timer
}

type Server struct {
	Clients         map[int]*Client
	PendingRequests map[int]*PendingRequest
	NextClientID    int
	NextRequestID   int
	mu              sync.Mutex
}

var server = Server{
	Clients:         make(map[int]*Client),
	PendingRequests: make(map[int]*PendingRequest),
}

func main() {
	portPtr := flag.String("port", "8080", "")
	flag.Parse()
	address := ":" + *portPtr

	listener, err := net.Listen("tcp", address)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Listening on %s\n", address)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Println("Accept error:", err)
			continue
		}
		go handleConnection(conn)
	}
}

func handleConnection(conn net.Conn) {
	defer conn.Close()

	client := &Client{
		Conn: conn,
		Send: make(chan []byte, 64),
		Done: make(chan struct{}),
	}

	server.mu.Lock()
	client.ID = server.NextClientID
	server.NextClientID++

	if len(server.Clients) == 0 {
		client.IsHost = true
	}

	server.Clients[client.ID] = client
	server.mu.Unlock()

	// Writer
	go func() {
		defer conn.Close()

		for {
			select {
			case msg, ok := <-client.Send:
				if !ok {
					return
				}
				_, err := conn.Write(msg)
				if err != nil {
					return
				}
			// Signal for writer stop
			case <-client.Done:
				return
			}
		}
	}()

	// Reader
	decoder := json.NewDecoder(conn)
	for {
		var msg map[string]any
		if err := decoder.Decode(&msg); err != nil {
			// Only log if it's not a normal disconnection
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				log.Printf("Read error client %d: %v", client.ID, err)
			}
			break
		}
		processMessage(client, msg)
	}

	removeClient(client)
}

func processMessage(client *Client, msg map[string]any) {

	// TODO: Handle non-string (malformed) fields, now expecting everything to be string
	event, _ := msg["event"].(string)

	// Handle handshake
	if event == "handshake" {
		newName, ok := msg["name"].(string)
		// TODO: Add limits
		if !ok || newName == "" {
			sendJSON(client, map[string]any{"event": "error", "message": "Invalid name"})
			return
		}

		server.mu.Lock()
		if client.Name == "" {
			client.Name = newName
			server.mu.Unlock()
			broadcast(nil, map[string]any{
				"event": "user_joined", "id": client.ID, "name": client.Name, "is_host": client.IsHost,
			})
		} else {
			// If second handshake ignore and unlock mutex to prevent deadlocks
			server.mu.Unlock()
		}

		return
	}

	if client.Name == "" {
		sendJSON(client, map[string]any{"event": "error", "message": "Set name first!"})
		return
	}

	// Handle standard broadcasts
	if event == "cursor_move" || event == "update_content" || event == "cursor_leave" {
		msg["from_id"] = client.ID
		msg["name"] = client.Name
		broadcast(client, msg)
		return
	}

	if reqIDFloat, ok := msg["request_id"].(float64); ok {
		reqID := int(reqIDFloat)

		var target *Client
		server.mu.Lock()
		if pending, exists := server.PendingRequests[reqID]; exists {
			target = server.Clients[pending.ClientID]

			pending.Timer.Stop()
			delete(server.PendingRequests, reqID)
		}
		server.mu.Unlock()

		if target != nil {
			sendJSON(target, msg)
		} else if reqID != 0 {
			log.Printf("Host replied to expired/unknown request id: %d", reqID)
		}
		return
	}

	server.mu.Lock()
	reqID := server.NextRequestID
	server.NextRequestID++

	pending := &PendingRequest{
		ClientID:  client.ID,
		RequestID: reqID,
	}

	pending.Timer = time.AfterFunc(RequestTimeout, func() {
		handleTimeout(reqID)
	})
	server.PendingRequests[reqID] = pending

	msg["request_id"] = reqID
	msg["from_id"] = client.ID

	var host *Client
	for _, c := range server.Clients {
		if c.IsHost {
			host = c
			break
		}
	}
	server.mu.Unlock()

	if host != nil {
		sendJSON(host, msg)
	} else {
		sendJSON(client, map[string]any{"event": "error", "message": "No host available :(((("})

		// If no host clean up the pending request
		server.mu.Lock()
		if p, exists := server.PendingRequests[reqID]; exists {
			p.Timer.Stop()
			delete(server.PendingRequests, reqID)
		}
		server.mu.Unlock()
	}
}

func removeClient(client *Client) {
	server.mu.Lock()

	if _, ok := server.Clients[client.ID]; !ok {
		server.mu.Unlock()
		return
	}

	close(client.Done)
	delete(server.Clients, client.ID)

	for id, req := range server.PendingRequests {
		if req.ClientID == client.ID {
			req.Timer.Stop()
			delete(server.PendingRequests, id)
		}
	}

	var newHostName string
	hasNewHost := false

	if client.IsHost && len(server.Clients) > 0 {
		for _, newHost := range server.Clients {
			newHost.IsHost = true
			newHostName = newHost.Name
			hasNewHost = true
			break
		}
	}

	leftID := client.ID
	leftName := client.Name

	server.mu.Unlock()

	broadcast(client, map[string]any{
		"event": "user_left", "id": leftID, "name": leftName,
	})

	if hasNewHost {
		broadcast(nil, map[string]any{
			"event": "new_host", "name": newHostName,
		})
	}
}

func handleTimeout(reqID int) {
	server.mu.Lock()
	defer server.mu.Unlock()

	req, ok := server.PendingRequests[reqID]
	if !ok {
		return
	}

	if client, ok := server.Clients[req.ClientID]; ok {
		sendJSON(client, map[string]any{
			"event":   "error",
			"message": "Timeout! Host is too incompetent",
		})
	}

	delete(server.PendingRequests, reqID)
}

func sendJSON(client *Client, data map[string]any) {
	bytes, err := json.Marshal(data)
	if err != nil {
		log.Printf("Error marshalling: %v", err)
		return
	}
	bytes = append(bytes, '\n')

	// Prevents locking if client is slow (non-blocking)
	select {
	case client.Send <- bytes:
	default:
		// Dropping (buffer full)
	}
}

func broadcast(sender *Client, data map[string]any) {
	bytes, err := json.Marshal(data)
	if err != nil {
		log.Printf("Error marshalling: %v", err)
		return
	}
	bytes = append(bytes, '\n')

	server.mu.Lock()
	targets := make([]*Client, 0, len(server.Clients))
	for _, c := range server.Clients {
		if sender == nil || c.ID != sender.ID {
			targets = append(targets, c)
		}
	}
	server.mu.Unlock()

	for _, c := range targets {
		select {
		case c.Send <- bytes:
		default:
			// Dropping
		}
	}
}
