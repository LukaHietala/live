package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
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
	// Channel buffer for messages, makes this thread-safe and non-blocking
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

	// Listen Send channel buf on another goroutine
	go func() {
		// Close the socket if anything weird happens
		defer conn.Close()

		for {
			select {
			case msg, ok := <-client.Send:
				if !ok {
					return
				}
				conn.Write(msg)
			// Signal for writer stop
			case <-client.Done:
				return
			}
		}
	}()
	// TODO: Maybe reader instead of scanner?
	scanner := bufio.NewScanner(conn)
	buf := make([]byte, 0, 64*1024)

	scanner.Buffer(buf, MaxBufferSize)

	// Read the connection and pass full messages handlers
	for scanner.Scan() {
		processMessage(client, scanner.Bytes())
	}

	if err := scanner.Err(); err != nil {
		log.Printf("Read error client %d: %v", client.ID, err)
	}

	removeClient(client)
}

func processMessage(client *Client, data []byte) {
	var msg map[string]any
	if err := json.Unmarshal(data, &msg); err != nil {
		log.Printf("JSON parse error: %v", err)
		return
	}

	// TODO: Handle non-string (malformed) fields, now expecting everything to be string
	event, _ := msg["event"].(string)
	// TODO?: Lock for minimal amount of time
	server.mu.Lock()
	defer server.mu.Unlock()

	// Handle handshake
	if event == "handshake" {
		newName, ok := msg["name"].(string)
		// TODO: Add limits
		if !ok || newName == "" {
			sendJSON(client, map[string]any{"event": "error", "message": "Invalid name"})
			return
		}

		if client.Name == "" {
			client.Name = newName
			broadcast(nil, map[string]any{
				"event": "user_joined", "id": client.ID, "name": client.Name, "is_host": client.IsHost,
			})
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

	// Handle host response (has request_id, treat as float cause paranoia)
	if reqIDFloat, ok := msg["request_id"].(float64); ok {
		reqID := int(reqIDFloat)

		// Find pending request
		if pending, exists := server.PendingRequests[reqID]; exists {
			// Forward to original sender
			if target, ok := server.Clients[pending.ClientID]; ok {
				sendJSON(target, msg)
			}
			// Cleanup
			pending.Timer.Stop()
			delete(server.PendingRequests, reqID)
		} else {
			log.Printf("Host replied to expired/unknown request id: %d", reqID)
		}
		return
	}

	// Handle request from regular client
	reqID := server.NextRequestID
	server.NextRequestID++

	pending := &PendingRequest{
		ClientID:  client.ID,
		RequestID: reqID,
	}

	// Timer for timeout
	pending.Timer = time.AfterFunc(RequestTimeout, func() {
		handleTimeout(reqID)
	})
	server.PendingRequests[reqID] = pending

	// Add metadata (from_id is not necessary but might be useful later)
	// All destination info's are gotten with request_id
	msg["request_id"] = reqID
	msg["from_id"] = client.ID

	// Find host and send request
	hostFound := false
	for _, c := range server.Clients {
		if c.IsHost {
			sendJSON(c, msg)
			hostFound = true
			break
		}
	}

	if !hostFound {
		sendJSON(client, map[string]any{"event": "error", "message": "No host available :(((("})
		pending.Timer.Stop()
		delete(server.PendingRequests, reqID)
	}
}

func removeClient(client *Client) {
	server.mu.Lock()
	defer server.mu.Unlock()

	// Double check if already removed
	if _, ok := server.Clients[client.ID]; !ok {
		return
	}

	// Signal write thread to stop graaacefully
	close(client.Done)
	delete(server.Clients, client.ID)

	broadcast(client, map[string]any{
		"event": "user_left", "id": client.ID, "name": client.Name,
	})

	// Cleanup requests from this client
	for id, req := range server.PendingRequests {
		if req.ClientID == client.ID {
			req.Timer.Stop()
			delete(server.PendingRequests, id)
		}
	}

	// "Elect" new host
	if client.IsHost && len(server.Clients) > 0 {
		// Go map iteration is random, so this picks a random new host :katti:
		for _, newHost := range server.Clients {
			newHost.IsHost = true
			broadcast(nil, map[string]any{
				"event": "new_host", "name": newHost.Name,
			})
			break
		}
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

	for _, c := range server.Clients {
		if sender == nil || c.ID != sender.ID {
			select {
			case c.Send <- bytes:
			default:
				// Dropping (buffer full)
			}
		}
	}
}
