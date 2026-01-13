#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "utils.h"

#define DEFAULT_PORT	8080
#define DEFAULT_BACKLOG 128
#define DEFAULT_TIMEOUT 5000 /* ms */

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
	struct client_node *next;
	struct client_node *prev;
} client_node_t;

int next_client_id = 0;
client_node_t *clients_head = NULL;

/* Pending requests */
typedef struct pending_request {
	int request_id;
	int client_id;
	uv_timer_t *timer;
	struct pending_request *next;
	struct pending_request *prev;
} pending_request_t;

int next_request_id = 0;
pending_request_t *requests_head = NULL;

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

/* Adds client to tracked clients */
void add_client(uv_stream_t *client)
{
	client_node_t *node = (client_node_t *)xmalloc(sizeof(client_node_t));

	node->client = client;
	node->id = next_client_id++;
	node->next = clients_head;
	node->prev = NULL;

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

	/* Cleanup pending requests that have this client to prevent dangling
	 * timers that nuke the app */
	pending_request_t *iter = requests_head;
	while (iter) {
		pending_request_t *next = iter->next;
		if (iter->client_id == node->id) {
			unlink_pending_request(iter);
			uv_timer_stop(iter->timer);
			uv_close((uv_handle_t *)iter->timer, on_timer_close);
		}
		iter = next;
	}

	if (node->is_host && node->prev != NULL)
		node->prev->is_host = 1;

	if (node->prev)
		node->prev->next = node->next;
	else
		clients_head = node->next;

	if (node->next)
		node->next->prev = node->prev;

	free(node);

	/* Make sure that pointer to this node doesn't linger in client stream
	 */
	client->data = NULL;
}

void free_write_req(uv_write_t *req)
{
	write_req_t *wr = (write_req_t *)req;
	free(wr->buf.base);
	free(wr);
}

void alloc_buffer(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
	buf->base = (char *)xmalloc(suggested_size);
	buf->len = suggested_size;
}

void on_close(uv_handle_t *handle)
{
	remove_client((uv_stream_t *)handle);
	free(handle);
}

void on_write_ready(uv_write_t *req, int status)
{
	if (status)
		fprintf(stderr, "Write error %s\n", uv_strerror(status));
	free_write_req(req);
}

/* Sends message to spesified stream */
void send_message(uv_stream_t *dest, const char *msg)
{
	write_req_t *req = (write_req_t *)xmalloc(sizeof(write_req_t));
	char *msg_copy = strdup(msg);

	req->buf = uv_buf_init(msg_copy, strlen(msg_copy));
	uv_write((uv_write_t *)req, dest, &req->buf, 1, on_write_ready);
}

/* Sends message to every client other than the sender. Message has to end with
 * newline */
void broadcast_message(uv_stream_t *sender, const char *msg)
{
	client_node_t *iter = clients_head;

	while (iter) {
		uv_stream_t *dest = iter->client;

		if (dest != sender)
			send_message(iter->client, msg);

		iter = iter->next;
	}
}

/* Notifies client on request timeout */
void on_request_timeout(uv_timer_t *handle)
{
	pending_request_t *req_data = (pending_request_t *)handle->data;

	uv_stream_t *client = find_client_stream_by_id(req_data->client_id);
	if (client) {
		const char *error_msg =
			"{\"event\": \"error\", \"data\": "
			"{\"message\": \"Timeout! Host is too "
			"incompetent to handle this request on time\"}}\n";
		send_message(client, error_msg);
	}

	unlink_pending_request(req_data);
	uv_close((uv_handle_t *)handle, on_timer_close);
}

void on_read(uv_stream_t *client, ssize_t nread, const uv_buf_t *buf)
{
	if (nread < 0) {
		if (nread != UV_EOF)
			fprintf(stderr, "Read error %s\n", uv_err_name(nread));
		uv_close((uv_handle_t *)client, on_close);
		free(buf->base);
		return;
	}

	cJSON *data_json = parse_json(buf->base, nread);

	if (data_json == NULL) {
		free(buf->base);
		return;
	}

	client_node_t *sender_node = (client_node_t *)client->data;

	cJSON *to_host_item =
		cJSON_GetObjectItemCaseSensitive(data_json, "to_host");
	cJSON *to_client_item =
		cJSON_GetObjectItemCaseSensitive(data_json, "to_client");

	/* If message has 'to_host' field set to true send the request to host
	 * with 'from_id' that identifies sender. 'from_id' is used by the host
	 * later to send reply to the client that made the request in the first
	 * place. This is for request events */
	if (cJSON_IsBool(to_host_item) && cJSON_IsTrue(to_host_item)) {
		/* Create a request */
		int req_id = next_request_id++;

		pending_request_t *req_context =
			xmalloc(sizeof(pending_request_t));
		req_context->request_id = req_id;
		req_context->client_id = sender_node->id;

		/* Setup libuv timer for timeouts */
		uv_timer_t *timer = xmalloc(sizeof(uv_timer_t));
		uv_timer_init(loop, timer);
		timer->data = req_context;
		req_context->timer = timer;

		uv_timer_start(timer, on_request_timeout, DEFAULT_TIMEOUT, 0);

		add_pending_request(req_context);

		cJSON_AddNumberToObject(data_json, "request_id", req_id);
		cJSON_AddNumberToObject(data_json, "from_id", sender_node->id);
		cJSON_DeleteItemFromObjectCaseSensitive(data_json, "to_host");

		char *request_str = stringify_json(data_json);

		client_node_t *iter = clients_head;
		while (iter) {
			if (iter->is_host) {
				send_message(iter->client, request_str);
				break;
			}
			iter = iter->next;
		}

		free(request_str);
	}
	/* If the message is a host's response to client, foward it to that
	   client based on 'to_client' field. This is for response events */
	else if (cJSON_IsNumber(to_client_item)) {
		/* Complete the request (remove from pending requests and stop
		 * timeout timers) */
		cJSON *req_id_item = cJSON_GetObjectItemCaseSensitive(
			data_json, "request_id");
		if (cJSON_IsNumber(req_id_item))
			complete_request(req_id_item->valueint);

		int client_id = to_client_item->valueint;
		uv_stream_t *dest = find_client_stream_by_id(client_id);

		cJSON_DeleteItemFromObjectCaseSensitive(data_json, "to_client");

		char *response_str = stringify_json(data_json);
		if (dest) {
			send_message(dest, response_str);
			free(response_str);
		}
	}
	/* If no 'to_client' or 'to_host' fields, broadcast to everyne. This for
	   broadcast events */
	else {
		char *broadcast_str = stringify_json(data_json);
		broadcast_message(client, broadcast_str);
		free(broadcast_str);
	}

	cJSON_Delete(data_json);
	free(buf->base);
}

void on_new_connection(uv_stream_t *server, int status)
{
	if (status < 0) {
		fprintf(stderr, "New connection error %s\n",
			uv_strerror(status));
		return;
	}

	uv_tcp_t *client = (uv_tcp_t *)xmalloc(sizeof(uv_tcp_t));
	uv_tcp_init(loop, client);
	if (uv_accept(server, (uv_stream_t *)client) == 0) {
		add_client((uv_stream_t *)client);
		uv_read_start((uv_stream_t *)client, alloc_buffer, on_read);
	} else {
		uv_close((uv_handle_t *)client, on_close);
	}
}

int main()
{
	loop = uv_default_loop();

	uv_tcp_t server;
	uv_tcp_init(loop, &server);

	uv_ip4_addr("0.0.0.0", DEFAULT_PORT, &addr);

	uv_tcp_bind(&server, (const struct sockaddr *)&addr, 0);
	int r = uv_listen((uv_stream_t *)&server, DEFAULT_BACKLOG,
			  on_new_connection);
	if (r) {
		fprintf(stderr, "Listen error %s\n", uv_strerror(r));
		return 1;
	}

	return uv_run(loop, UV_RUN_DEFAULT);
}
