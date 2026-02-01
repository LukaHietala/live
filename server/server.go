package main

import (
	"bufio"
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
	mu              sync.RWMutex
}

var server = Server{
	Clients:         make(map[int]*Client),
	PendingRequests: make(map[int]*PendingRequest),
}

func main() {
	portPtr := flag.String("port", "8080", "")
	flag.Parse()
	address := ":" + *portPtr

	server := &Server{
		Clients:         make(map[int]*Client),
		PendingRequests: make(map[int]*PendingRequest),
	}

	listener, err := net.Listen("tcp", address)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	fmt.Printf("Listening on %s\n", address)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Println("Accept error:", err)
			continue
		}
		go server.handleConnection(conn)
	}
}

func (s *Server) handleConnection(conn net.Conn) {
	defer conn.Close()

	client := &Client{
		Conn: conn,
		// 64 slots (24 bytes each, 24x64 is around 1.5 KB) for each client's buffer
		// If it is full start dropping (connection is usually fatally slow or broken)
		Send: make(chan []byte, 64),
		// Signals writer to stop
		Done: make(chan struct{}),
	}

	// Add client metadata
	s.mu.Lock()
	client.ID = s.NextClientID
	s.NextClientID++

	// If no other clients, make this the host
	if len(s.Clients) == 0 {
		client.IsHost = true
	}

	s.Clients[client.ID] = client
	s.mu.Unlock()

	// Writer
	go func() {
		defer conn.Close()

		for {
			select {
			// From Send buffer write to the actual connection
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
	scanner := bufio.NewScanner(conn)
	// Start with 64KB
	buf := make([]byte, 0, 64*1024)
	// Cap to max size
	scanner.Buffer(buf, MaxBufferSize)

	for scanner.Scan() {
		var msg map[string]any

		err := json.Unmarshal(scanner.Bytes(), &msg)
		if err != nil {
			log.Printf("JSON unmarshal error client %d: %v", client.ID, err)
			continue
		}

		s.processMessage(client, msg)
	}

	err := scanner.Err()
	if err != nil {
		if errors.Is(err, bufio.ErrTooLong) {
			log.Printf("Client %d sent too big message", client.ID)
		} else if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
			log.Printf("Read error client %d: %v", client.ID, err)
		}
	}
	s.removeClient(client)
}

func (s *Server) processMessage(client *Client, msg map[string]any) {

	// TODO: Handle non-string (malformed) fields, now expecting everything to be string
	event, _ := msg["event"].(string)

	// Handle handshake
	if event == "handshake" {
		newName, ok := msg["name"].(string)
		// TODO: Add limits
		if !ok || newName == "" {
			s.sendJSON(client, map[string]any{"event": "error", "message": "Invalid name"})
			return
		}

		s.mu.Lock()
		if client.Name == "" {
			client.Name = newName
			s.mu.Unlock()
			s.broadcast(nil, map[string]any{
				"event": "user_joined", "id": client.ID, "name": client.Name, "is_host": client.IsHost,
			})
		} else {
			// If second handshake ignore and unlock mutex to prevent deadlocks
			s.mu.Unlock()
		}

		return
	}

	if client.Name == "" {
		s.sendJSON(client, map[string]any{"event": "error", "message": "Set name first!"})
		return
	}

	// Handle standard broadcasts
	if event == "cursor_move" || event == "update_content" || event == "cursor_leave" {
		msg["from_id"] = client.ID
		msg["name"] = client.Name
		s.broadcast(client, msg)
		return
	}

	if reqIDFloat, ok := msg["request_id"].(float64); ok {
		reqID := int(reqIDFloat)

		var target *Client
		s.mu.Lock()
		pending, exists := s.PendingRequests[reqID]
		if exists {
			target = s.Clients[pending.ClientID]

			pending.Timer.Stop()
			delete(s.PendingRequests, reqID)
		}
		s.mu.Unlock()

		if target != nil {
			s.sendJSON(target, msg)
		} else if reqID != 0 {
			log.Printf("Host replied to expired/unknown request id: %d", reqID)
		}
		return
	}

	s.mu.Lock()
	reqID := s.NextRequestID
	s.NextRequestID++

	pending := &PendingRequest{
		ClientID:  client.ID,
		RequestID: reqID,
	}

	pending.Timer = time.AfterFunc(RequestTimeout, func() {
		s.handleTimeout(reqID)
	})
	s.PendingRequests[reqID] = pending

	msg["request_id"] = reqID
	msg["from_id"] = client.ID

	// TODO: Move host to Server struct
	var host *Client
	for _, c := range s.Clients {
		if c.IsHost {
			host = c
			break
		}
	}
	s.mu.Unlock()

	if host != nil {
		s.sendJSON(host, msg)
	} else {
		s.sendJSON(client, map[string]any{"event": "error", "message": "No host available :(((("})

		// If no host clean up the pending request
		s.mu.Lock()
		p, exists := s.PendingRequests[reqID]
		if exists {
			p.Timer.Stop()
			delete(s.PendingRequests, reqID)
		}
		s.mu.Unlock()
	}
}

func (s *Server) removeClient(client *Client) {
	s.mu.Lock()

	// Make sure exits
	if _, ok := s.Clients[client.ID]; !ok {
		s.mu.Unlock()
		return
	}

	// Close the connection gracefully
	close(client.Done)
	delete(s.Clients, client.ID)

	// Clear any pending requests
	for id, req := range s.PendingRequests {
		if req.ClientID == client.ID {
			req.Timer.Stop()
			delete(s.PendingRequests, id)
		}
	}

	// Randomly pick new host
	// TODO: Make not random
	var newHostName string
	hasNewHost := false

	if client.IsHost && len(s.Clients) > 0 {
		for _, newHost := range s.Clients {
			newHost.IsHost = true
			newHostName = newHost.Name
			hasNewHost = true
			break
		}
	}

	// Store client info before unlock
	leftID := client.ID
	leftName := client.Name

	s.mu.Unlock()

	s.broadcast(client, map[string]any{
		"event": "user_left", "id": leftID, "name": leftName,
	})

	if hasNewHost {
		s.broadcast(nil, map[string]any{
			"event": "new_host", "name": newHostName,
		})
	}
}

func (s *Server) handleTimeout(reqID int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	req, ok := s.PendingRequests[reqID]
	if !ok {
		return
	}

	if client, ok := s.Clients[req.ClientID]; ok {
		s.sendJSON(client, map[string]any{
			"event":   "error",
			"message": "Timeout! Host is too incompetent",
		})
	}

	delete(s.PendingRequests, reqID)
}

func (s *Server) sendJSON(client *Client, data map[string]any) {
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

func (s *Server) broadcast(sender *Client, data map[string]any) {
	bytes, err := json.Marshal(data)
	if err != nil {
		log.Printf("Error marshalling: %v", err)
		return
	}
	bytes = append(bytes, '\n')

	// Minimize locking by getting targets beforehand
	s.mu.RLock()
	targets := make([]*Client, 0, len(s.Clients))
	for _, c := range s.Clients {
		if sender == nil || c.ID != sender.ID {
			targets = append(targets, c)
		}
	}
	s.mu.RUnlock()

	for _, c := range targets {
		select {
		case c.Send <- bytes:
		default:
			// Dropping
		}
	}
}
