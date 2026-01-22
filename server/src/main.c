#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "utils.h"

#define DEFAULT_PORT	8080
#define DEFAULT_BACKLOG 128
#define DEFAULT_TIMEOUT 5000 /* ms */
/* 10 MB, should be enough for any text file. If not,...???*/
#define MAX_BUFFER_SIZE (10 * 1024 * 1024)

uv_loop_t *loop;
struct sockaddr_in addr;

typedef struct {
	uv_write_t req;
	uv_buf_t buf;
} write_req_t;

/* Connected clients */
typedef struct client_node {
	uv_stream_t *client;
	int id;
	int is_host;
	char *name;
	struct circular_buffer buffer;
	struct client_node *next;
	struct client_node *prev;
} client_node_t;

int next_client_id = 0;
client_node_t *clients_head = NULL;

/* Pending requests, TODO: Make slot based system if performance becomes an
 * issue */
typedef struct pending_request {
	int request_id;
	int client_id;
	uv_timer_t *timer;
	struct pending_request *next;
	struct pending_request *prev;
} pending_request_t;

int next_request_id = 0;
pending_request_t *requests_head = NULL;

/* Foward defs, TODO: move to headers */
void free_write_req(uv_write_t *req);
void alloc_buffer(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf);

void add_pending_request(pending_request_t *req);
void unlink_pending_request(pending_request_t *req);
void complete_request(int request_id);
void add_client(uv_stream_t *client);
void remove_client(uv_stream_t *client);
uv_stream_t *find_client_stream_by_id(int id);

void send_message(uv_stream_t *dest, const char *msg);
void broadcast_message(uv_stream_t *sender, const char *msg);

void on_timer_close(uv_handle_t *handle);
void on_close(uv_handle_t *handle);
void on_write_ready(uv_write_t *req, int status);
void on_request_timeout(uv_timer_t *handle);
void on_read(uv_stream_t *client, ssize_t nread, const uv_buf_t *buf);
void on_new_connection(uv_stream_t *server, int status);

/* Add request to the tracking list */
void add_pending_request(pending_request_t *req)
{
	req->next = requests_head;
	req->prev = NULL;

	if (requests_head)
		requests_head->prev = req;

	requests_head = req;
}

/* Callback, on timer closes free the pending request */
void on_timer_close(uv_handle_t *handle)
{
	pending_request_t *req = (pending_request_t *)handle->data;

	if (req)
		free(req);

	free(handle);
}

/* Unlink request from list (does not free memory) */
void unlink_pending_request(pending_request_t *req)
{
	if (req->prev)
		req->prev->next = req->next;
	else
		requests_head = req->next;

	if (req->next)
		req->next->prev = req->prev;
}

/* Find and remove a request by request id (stops timer and frees) */
void complete_request(int request_id)
{
	pending_request_t *iter = requests_head;
	while (iter) {
		if (iter->request_id == request_id) {
			unlink_pending_request(iter);

			uv_timer_stop(iter->timer);

			uv_close((uv_handle_t *)iter->timer, on_timer_close);
			return;
		}
		iter = iter->next;
	}
}

/* Returns client's uv_stream by id */
uv_stream_t *find_client_stream_by_id(int id)
{
	client_node_t *iter = clients_head;
	while (iter) {
		if (iter->id == id)
			return iter->client;
		iter = iter->next;
	}
	return NULL;
}

/* Adds client to tracked clients (nodes), which contain the actual stream and
 * any additional metadata */
void add_client(uv_stream_t *client)
{
	client_node_t *node = (client_node_t *)xmalloc(sizeof(client_node_t));

	node->client = client;
	node->id = next_client_id++;
	node->name = NULL;
	node->next = clients_head;
	node->prev = NULL;

	/* Read buffers, start with 1KB and go on from there */
	cb_init(&(node->buffer), 1024);

	/* If this is the first client to join make it the host */
	if (clients_head == NULL) {
		node->is_host = 1;
	} else {
		node->is_host = 0;
		clients_head->prev = node;
	}

	clients_head = node;

	/* Store this node's pointer in client, to later use for other
	 * functions. Libuv provides this really useful data field for arbituary
	 * data */
	client->data = node;
}

/* Removes client from tracked clients */
void remove_client(uv_stream_t *client)
{
	client_node_t *node = (client_node_t *)client->data;

	if (node == NULL)
		return;

	cJSON *event_json = cJSON_CreateObject();
	cJSON_AddStringToObject(event_json, "event", "user_left");
	cJSON_AddNumberToObject(event_json, "id", node->id);
	cJSON_AddStringToObject(event_json, "name", node->name);

	char *event_str = stringify_json(event_json);
	broadcast_message(client, event_str);

	cJSON_Delete(event_json);
	free(event_str);

	/* Cleanup pending requests that have this client to prevent dangling
	 * timers that nuke the app */
	pending_request_t *iter = requests_head;
	while (iter) {
		pending_request_t *next = iter->next;
		if (iter->client_id == node->id) {
			unlink_pending_request(iter);
			uv_timer_stop(iter->timer);
			/* Link iter to timer to make sure it doesn't dangle */
			iter->timer->data = iter;
			uv_close((uv_handle_t *)iter->timer, on_timer_close);
		}
		iter = next;
	}

	/* Appoint new host, TODO: instead of making the second oldest client
	 * the host, make the app work without a host and if there isn't host
	 * any client can claim the host powers */
	client_node_t *new_host = NULL;

	if (node->is_host) {
		if (node->next) {
			node->next->is_host = 1;
			new_host = node->next;
		} else if (node->prev) {
			node->prev->is_host = 1;
			new_host = node->prev;
		}
	}

	if (node->prev)
		node->prev->next = node->next;
	else
		clients_head = node->next;

	if (node->next)
		node->next->prev = node->prev;

	/* If new host was elected send event about it */
	if (node->is_host && new_host) {
		char msg[128];
		/* TODO: Limit name size and make sure that this doesn't
		 * overflow. Maybe cJSON? */
		snprintf(msg, sizeof(msg),
			 "{\"event\":\"new_host\",\"name\":\"%s\"}\n",
			 new_host->name);

		broadcast_message(NULL, msg);
	}

	if (node->buffer.buffer)
		cb_free(&(node->buffer));

	if (node->name)
		free(node->name);
	free(node);

	/* Make sure that pointer to this node doesn't linger in client stream
	 */
	client->data = NULL;
}

/* Called by on_write_ready to cleanup write req and it's data */
void free_write_req(uv_write_t *req)
{
	write_req_t *wr = (write_req_t *)req;
	free(wr->buf.base);
	free(wr);
}

/* Allocates a new buffer space on read, libuv provides the suggested size for
 * it based on kernel's socket receive buffer so we don't have to worry about it
 */
void alloc_buffer(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
	buf->base = (char *)xmalloc(suggested_size);
	buf->len = suggested_size;
}

/* On disconnect for example. Libuv provides the disconnected client's handle
 * and based on that we can delete and free all client data and the handle
 * itself */
void on_close(uv_handle_t *handle)
{
	remove_client((uv_stream_t *)handle);
	free(handle);
}

/* When write is ready, libuv calls this the request data and status */
void on_write_ready(uv_write_t *req, int status)
{
	if (status)
		fprintf(stderr, "[error] Write error %s\n",
			uv_strerror(status));
	free_write_req(req);
}

/* Notifies client on request timeout, we provide the handle */
void on_request_timeout(uv_timer_t *handle)
{
	pending_request_t *req_data = (pending_request_t *)handle->data;

	uv_stream_t *client = find_client_stream_by_id(req_data->client_id);
	if (client) {
		cJSON *error_json = cJSON_CreateObject();
		cJSON_AddStringToObject(error_json, "event", "error");
		cJSON *data_json = cJSON_AddObjectToObject(error_json, "data");
		cJSON_AddStringToObject(data_json, "type", "timeout");
		cJSON_AddStringToObject(data_json, "message",
					"Timeout! Host is too incompetent to "
					"handle this request on time");

		char *error_str = stringify_json(error_json);

		send_message(client, error_str);

		cJSON_Delete(error_json);
		free(error_str);
	}

	unlink_pending_request(req_data);
	uv_close((uv_handle_t *)handle, on_timer_close);
}

/* Sends message to spesified stream */
void send_message(uv_stream_t *dest, const char *msg)
{
	/* Dont even begin to do anything if destination is closing, this is
	 * technically against the libuv docs but shouldn't cause any issues */
	if (uv_is_closing((uv_handle_t *)dest))
		return;

	client_node_t *node = (client_node_t *)dest->data;
	if (node) {
		printf("[info] Sending %zu bytes to client %d (%s): %s",
		       strlen(msg), node->id, node->name, msg);
	} else {
		printf("[info] Sending %zu bytes to... somewhere: %s",
		       strlen(msg), msg);
	}

	write_req_t *req = (write_req_t *)xmalloc(sizeof(write_req_t));
	char *msg_copy = strdup(msg);

	req->buf = uv_buf_init(msg_copy, strlen(msg_copy));
	int r = uv_write((uv_write_t *)req, dest, &req->buf, 1, on_write_ready);

	/* If writing fails clean up */
	if (r < 0) {
		fprintf(stderr, "[info] uv_write failed: %s\n", uv_strerror(r));
		free_write_req((uv_write_t *)req);
	}
}

/* Sends message to every client other than the sender. Message has to end with
 * newline */
void broadcast_message(uv_stream_t *sender, const char *msg)
{
	if (msg == NULL)
		return;

	client_node_t *sender_node =
		sender ? (client_node_t *)sender->data : NULL;

	if (sender_node) {
		printf("[info] Broadcasting %zu bytes from client %d (%s): %s",
		       strlen(msg), sender_node->id, sender_node->name, msg);
	} else {
		printf("[info] Broadcasting %zu bytes to everyone: %s",
		       strlen(msg), msg);
	}
	client_node_t *iter = clients_head;

	while (iter) {
		uv_stream_t *dest = iter->client;

		/* If no sender (server broadcast) send to everyone, if sender
		 * send to everyone except the sender */
		if (sender == NULL || dest != sender)
			send_message(iter->client, msg);

		iter = iter->next;
	}
}

/* Processes every full message ending with newline */
void process_message(uv_stream_t *client, const char *msg_str)
{
	/* Parse json message */
	cJSON *data_json = cJSON_Parse(msg_str);
	if (data_json == NULL) {
		fprintf(stderr, "[error] Failed to parse json: %s\n", msg_str);
		return;
	}

	/* Get the sender from client stream, if for example we need to identify
	 * it for commands like 'set_name' */
	client_node_t *sender_node = (client_node_t *)client->data;

	cJSON *event_item =
		cJSON_GetObjectItemCaseSensitive(data_json, "event");
	cJSON *name_item = cJSON_GetObjectItemCaseSensitive(data_json, "name");

	/* TODO: Make dedicated event handler */
	if (cJSON_IsString(event_item) &&
	    strcmp(event_item->valuestring, "handshake") == 0) {
		if (!cJSON_IsString(name_item) ||
		    name_item->valuestring == NULL) {
			send_message(client, "{\"event\":\"error\",\"message\":"
					     "\"Invalid name provided\"}\n");
			goto cleanup;
		}

		int is_first_time = (sender_node->name == NULL);

		if (!is_first_time)
			free(sender_node->name);
		sender_node->name = strdup(name_item->valuestring);

		if (is_first_time) {
			/* Broadcast user joined */
			cJSON *join_json = cJSON_CreateObject();
			cJSON_AddStringToObject(join_json, "event",
						"user_joined");
			cJSON_AddNumberToObject(join_json, "id",
						sender_node->id);
			cJSON_AddStringToObject(join_json, "name",
						sender_node->name);
			cJSON_AddBoolToObject(join_json, "is_host",
					      sender_node->is_host);

			char *join_str = stringify_json(join_json);
			broadcast_message(NULL, join_str);

			cJSON_Delete(join_json);
			free(join_str);
		} else {
			/* Broadcast name change */
			cJSON *event_json = cJSON_CreateObject();
			cJSON_AddStringToObject(event_json, "event",
						"name_changed");
			cJSON_AddNumberToObject(event_json, "id",
						sender_node->id);
			cJSON_AddStringToObject(event_json, "new_name",
						sender_node->name);

			char *event_str = stringify_json(event_json);
			broadcast_message(client, event_str);

			cJSON_Delete(event_json);
			free(event_str);
		}
		goto cleanup;
	}

	if (sender_node->name == NULL) {
		/* TODO: Make errors more standard */
		send_message(client, "{\"event\":\"error\",\"message\":\"Set "
				     "name first!\"}\n");
		goto cleanup;
	}

	/* Events to broadcast */
	if (cJSON_IsString(event_item)) {
		const char *event_name = event_item->valuestring;

		if (strcmp(event_name, "cursor_move") == 0 ||
		    strcmp(event_name, "update_content") == 0 ||
		    strcmp(event_name, "cursor_leave") == 0) {
			cJSON_AddNumberToObject(data_json, "from_id",
						sender_node->id);
			cJSON_AddStringToObject(data_json, "name",
						sender_node->name);

			char *broadcast_str = stringify_json(data_json);
			if (broadcast_str) {
				broadcast_message(client, broadcast_str);
				free(broadcast_str);
			}

			goto cleanup;
		}
	}

	/* Per event routing, some events like request_files fill be fowarded to
	 * host with request id, and host can respond to that with correct event
	 * like response_files with that same request_id. The response will be
	 * fowarded to the corrrect client by the request id. This is to try to
	 * keep the clients as stateless as possible to keep consitency. And if
	 * client wants to broadcast something or do something "not default" it
	 * must be handle on per basis. */
	cJSON *req_id_item =
		cJSON_GetObjectItemCaseSensitive(data_json, "request_id");

	/* If message has request_id, its from host so this is for response
	 * events */
	if (cJSON_IsNumber(req_id_item)) {
		int req_id = req_id_item->valueint;
		int target_client_id = -1;

		/* Find the pending request to discover who sent it
		 * originally */
		pending_request_t *iter = requests_head;
		while (iter) {
			if (iter->request_id == req_id) {
				target_client_id = iter->client_id;
				break;
			}
			iter = iter->next;
		}

		/* If found, forward the message to that client */
		if (target_client_id != -1) {
			uv_stream_t *dest =
				find_client_stream_by_id(target_client_id);

			char *response_str = stringify_json(data_json);
			if (dest)
				send_message(dest, response_str);
			free(response_str);

			/* Mark request as complete (stops timer, frees
			 * memory) */
			complete_request(req_id);
		} else {
			/* Request is not found (maybe timed out already?) */
			fprintf(stderr,
				"[warn] Host replied to expired or unknown "
				"request ID: %d\n",
				req_id);
		}

		goto cleanup;
	}
	/* Host broadcasting. If sender is host and it's NOT a response event(no
	 * request_id), broadcast to everyone. If client want to broadcat
	 * something, that must be handled spesifically per event.
	 */
	else if (sender_node->is_host) {
		char *broadcast_str = stringify_json(data_json);
		broadcast_message(client, broadcast_str);
		free(broadcast_str);
	}
	/* Any other message from a non-host client is treated as a request. */
	else {
		int req_id = next_request_id++;

		/* Creates a pending request context */
		pending_request_t *req_context =
			(pending_request_t *)xmalloc(sizeof(pending_request_t));
		req_context->request_id = req_id;
		req_context->client_id = sender_node->id;

		/* Adds timer to that pending request */
		uv_timer_t *timer = (uv_timer_t *)xmalloc(sizeof(uv_timer_t));
		uv_timer_init(loop, timer);
		timer->data = req_context;
		req_context->timer = timer;

		/* Start timer and add to list */
		uv_timer_start(timer, on_request_timeout, DEFAULT_TIMEOUT, 0);
		add_pending_request(req_context);

		/* Inject metadata for host so it knows who sent it and the id
		 */
		cJSON_AddNumberToObject(data_json, "request_id", req_id);
		/* Host doesn't need this for routing but it can be useful for
		 * client to know who exactly is sending an request event */
		cJSON_AddNumberToObject(data_json, "from_id", sender_node->id);

		char *request_str = stringify_json(data_json);

		/* Find host and forward the request */
		client_node_t *iter = clients_head;
		int host_found = 0;
		while (iter) {
			if (iter->is_host) {
				send_message(iter->client, request_str);
				host_found = 1;
				break;
			}
			iter = iter->next;
		}

		if (!host_found) {
			send_message(client, "{\"event\":\"error\",\"message\":"
					     "\"No host available\"}\n");
			complete_request(req_id);
		}

		free(request_str);
	}
cleanup:
	cJSON_Delete(data_json);
}

/* Main function for reading data from libuv */
void on_read(uv_stream_t *client, ssize_t nread, const uv_buf_t *buf)
{
	client_node_t *node = (client_node_t *)client->data;
	fprintf(stderr, "[debug] Amount of unparsed data left: %ld\n",
		node->buffer.amount);

	/* If client disconnects "loudly" then close it, keepalive will handle
	 * more silent disconnects, but a heartbeat system might be added later
	 */
	if (nread < 0) {
		if (nread != UV_EOF)
			fprintf(stderr, "[error] Read error %s\n",
				uv_err_name(nread));

		uv_close((uv_handle_t *)client, on_close);
		if (buf->base)
			free(buf->base);

		return;
	}

	if (nread > 0) {
		/* Make sure that the client' read buffer size doesn't get too
		 * large. If client tries to hog more that 10MB memory kick it
		 * out */
		if (node->buffer.amount + nread > MAX_BUFFER_SIZE) {
			fprintf(stderr,
				"[error] Client %d sent too much data (<%zu "
				"bytes). Sending couple petabytes to "
				"retaliate\n",
				node->id, node->buffer.amount + nread);

			uv_close((uv_handle_t *)client, on_close);

			if (buf->base)
				free(buf->base);
			return;
		}
		/* Check the capacity and if not enough allocate more memory to
		 * it */
		while (node->buffer.amount + nread > node->buffer.size) {
			size_t new_capacity = node->buffer.size * 2;
			/* Not using xrealloc here, because usually the sizes
			 * that this is allocating are huge and server might not
			 * have enough space for it. So to reduce crashes just
			 * kick it out already */
			cb_realloc(&(node->buffer), new_capacity);

			if (!node->buffer.buffer) {
				fprintf(stderr, "[error] Out of memory! "
						"Dropping misbehaving client");
				uv_close((uv_handle_t *)client, on_close);
				free(buf->base);
				return;
			}
		}

		/* Copy new data to read buffer */
		cb_push_data(&(node->buffer), buf->base, nread);

		/* Process complete messages, delimeter being \n. This
		 * shouldn't cause any problems with json content because they
		 * "should" escape the newline */
		char *buf_string;
		while ((buf_string = cb_get_string(&(node->buffer)))) {
			process_message(client, buf_string);
			/* cb_get_string will replace \n with \0 as well as
			 * possibly allocating a new temporary buffer, this
			 * will clean up any undesired complications. */
			cb_clean_string(&(node->buffer));
		}
	}
	if (buf->base)
		free(buf->base);
}

/* Called on new connection. Libuv provides client's stream handle and status.
 * Then accept the client and start listening it */
void on_new_connection(uv_stream_t *server, int status)
{
	if (status < 0) {
		fprintf(stderr, "[error] New connection error %s\n",
			uv_strerror(status));
		return;
	}

	/* Create new tcp handle for client */
	uv_tcp_t *client = (uv_tcp_t *)xmalloc(sizeof(uv_tcp_t));
	uv_tcp_init(loop, client);
	/* Accept, start read and add as "client_node" */
	if (uv_accept(server, (uv_stream_t *)client) == 0) {
		uv_tcp_keepalive(client, 1, 60);
		add_client((uv_stream_t *)client);
		uv_read_start((uv_stream_t *)client, alloc_buffer, on_read);
	} else {
		uv_close((uv_handle_t *)client, on_close);
	}
}

int main()
{
	/* If client tries to write to closed socket it will send SIGPIPE and
	 * crash the app. This handles it gracefully */
	signal(SIGPIPE, SIG_IGN);

	/* Start libuv main loop */
	loop = uv_default_loop();

	/* Create and bind the server to a socket and start listening */
	uv_tcp_t server;
	uv_tcp_init(loop, &server);

	uv_ip4_addr("0.0.0.0", DEFAULT_PORT, &addr);

	uv_tcp_bind(&server, (const struct sockaddr *)&addr, 0);
	int r = uv_listen((uv_stream_t *)&server, DEFAULT_BACKLOG,
			  on_new_connection);
	if (r) {
		fprintf(stderr, "[error] Listen error %s\n", uv_strerror(r));
		return 1;
	}

	return uv_run(loop, UV_RUN_DEFAULT);
}
