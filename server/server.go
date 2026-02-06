package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"time"
)

const (
	RequestTimeout = 5 * time.Second
	MaxBufferSize  = 5 * 1024 * 1024
)

type Client struct {
	Conn   net.Conn
	ID     int
	Name   string
	IsHost bool
	// Channel buffer for all messages, ONLY WRITE TO THIS
	Send chan []byte
}

type PendingRequest struct {
	ClientID  int
	RequestID int
	Timer     *time.Timer
}

type Server struct {
	Clients         map[int]*Client
	Host            *Client
	PendingRequests map[int]*PendingRequest
	NextClientID    int
	NextRequestID   int
	actions         chan func()
}

func NewServer() *Server {
	return &Server{
		Clients:         make(map[int]*Client),
		PendingRequests: make(map[int]*PendingRequest),
		actions:         make(chan func(), 1024),
	}
}

func main() {
	portPtr := flag.String("port", "8080", "")
	flag.Parse()
	address := ":" + *portPtr

	server := NewServer()
	go server.run()

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

func (s *Server) run() {
	for action := range s.actions {
		action()
	}
}

func (s *Server) handleConnection(conn net.Conn) {
	client := &Client{
		Conn: conn,
		Send: make(chan []byte, 64),
	}

	// Joining
	s.actions <- func() {
		client.ID = s.NextClientID
		s.NextClientID++
		if s.Host == nil {
			client.IsHost = true
			s.Host = client
		} else {
			client.IsHost = false
		}
		s.Clients[client.ID] = client
	}

	// Writer goroutine
	done := make(chan struct{})
	go func() {
		defer conn.Close()
		for msg := range client.Send {
			_, err := conn.Write(msg)
			if err != nil {
				break
			}
		}
		close(done)
	}()

	// Reader
	scanner := bufio.NewScanner(conn)
	// 64 KB by default
	scanner.Buffer(make([]byte, 0, 64*1024), MaxBufferSize)

	for scanner.Scan() {
		var msg map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			continue
		}
		log.Println(string(scanner.Bytes()))
		// Send task to the "manager"
		s.actions <- func() {
			s.processMessage(client, msg)
		}
	}

	// Leave/disconnect
	s.actions <- func() {
		s.removeClient(client)
	}
}

func (s *Server) processMessage(client *Client, msg map[string]any) {
	event, _ := msg["event"].(string)

	// Handshake (add necessary info to client)
	if event == "handshake" {
		s.handleHandshake(client, msg)
		return
	}

	// Name is required for all other events
	if client.Name == "" {
		s.sendJSON(client, map[string]any{"event": "error", "message": "Set name first!"})
		return
	}

	// Route events by type
	switch event {
	// To broadcast
	case "cursor_move", "update_content", "cursor_leave":
		msg["from_id"] = client.ID
		msg["name"] = client.Name
		s.broadcast(client.ID, msg)
		// Requests to host
	default:
		// Request/Response
		if reqIDFloat, ok := msg["request_id"].(float64); ok {
			s.resolvePendingRequest(int(reqIDFloat), msg)
		} else {
			s.createNewRequest(client, msg)
		}
	}
}

func (s *Server) handleHandshake(client *Client, msg map[string]any) {
	newName, _ := msg["name"].(string)
	if newName != "" && client.Name == "" {
		client.Name = newName
		s.broadcast(-1, map[string]any{
			"event": "user_joined", "id": client.ID,
			"name":    client.Name,
			"is_host": client.IsHost,
		})
	}
}

// Deletes pending request (successful response :D)
func (s *Server) resolvePendingRequest(reqID int, msg map[string]any) {
	if pending, exists := s.PendingRequests[reqID]; exists {
		if target, ok := s.Clients[pending.ClientID]; ok {
			delete(msg, "request_id")
			s.sendJSON(target, msg)
		}
		pending.Timer.Stop()
		delete(s.PendingRequests, reqID)
	}
}

func (s *Server) createNewRequest(client *Client, msg map[string]any) {
	reqID := s.NextRequestID
	s.NextRequestID++

	pending := &PendingRequest{
		ClientID:  client.ID,
		RequestID: reqID,
	}
	pending.Timer = time.AfterFunc(RequestTimeout, func() {
		s.actions <- func() {
			s.handleTimeout(reqID)
		}
	})
	s.PendingRequests[reqID] = pending

	msg["request_id"] = reqID
	msg["from_id"] = client.ID

	if host := s.getHost(); host != nil {
		s.sendJSON(host, msg)
	} else {
		s.sendJSON(client, map[string]any{"event": "error", "message": "No host available"})
		pending.Timer.Stop()
		delete(s.PendingRequests, reqID)
	}
}

func (s *Server) getHost() *Client {
	if s.Host == nil {
		return nil
	}
	if _, ok := s.Clients[s.Host.ID]; ok {
		return s.Host
	}
	return nil
}

func (s *Server) removeClient(client *Client) {
	if _, ok := s.Clients[client.ID]; !ok {
		return
	}

	delete(s.Clients, client.ID)
	close(client.Send)

	for id, req := range s.PendingRequests {
		if req.ClientID == client.ID {
			req.Timer.Stop()
			delete(s.PendingRequests, id)
		}
	}

	if client.IsHost && len(s.Clients) > 0 {
		s.Host = nil
		for _, c := range s.Clients {
			c.IsHost = true
			s.Host = c

			s.broadcast(-1, map[string]any{
				"event":   "new_host",
				"host_id": c.ID,
				"name":    c.Name,
			})
			break
		}
	}

	s.broadcast(-1, map[string]any{"event": "user_left", "id": client.ID, "name": client.Name})
}

func (s *Server) handleTimeout(reqID int) {
	req, ok := s.PendingRequests[reqID]
	if !ok {
		return
	}
	client, ok := s.Clients[req.ClientID]
	if ok {
		s.sendJSON(client, map[string]any{"event": "error", "message": "Timeout! Incompetent host"})
	}
	delete(s.PendingRequests, reqID)
}

func (s *Server) sendJSON(client *Client, data map[string]any) {
	bytes, _ := json.Marshal(data)
	bytes = append(bytes, '\n')
	select {
	case client.Send <- bytes:
	default:
		// Buffer full, dropping
	}
}

func (s *Server) broadcast(senderID int, data map[string]any) {
	bytes, _ := json.Marshal(data)
	bytes = append(bytes, '\n')

	for _, c := range s.Clients {
		if c.ID != senderID {
			select {
			case c.Send <- bytes:
			default:
				// Buffer full, dropping
			}
		}
	}
}
