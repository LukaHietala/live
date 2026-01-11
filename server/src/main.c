#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "utils.h"

#define DEFAULT_PORT	8080
#define DEFAULT_BACKLOG 128

uv_loop_t *loop;
struct sockaddr_in addr;

typedef struct {
	uv_write_t req;
	uv_buf_t buf;
} write_req_t;

/* Connected clients */
typedef struct client_node {
	uv_stream_t *client;
	int is_host;
	struct client_node *next;
	struct client_node *prev;
} client_node_t;

/* Latest client */
client_node_t *clients_head = NULL;

/* Adds client to tracked clients */
void add_client(uv_stream_t *client)
{
	client_node_t *node = (client_node_t *)xmalloc(sizeof(client_node_t));

	node->client = client;
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

void echo_write(uv_write_t *req, int status)
{
	if (status)
		fprintf(stderr, "Write error %s\n", uv_strerror(status));
	free_write_req(req);
}

/* Sends message to every client other than the sender. Message has to end with
 * newline */
void broadcast_message(uv_stream_t *sender, const char *msg)
{
	client_node_t *iter = clients_head;

	while (iter) {
		uv_stream_t *dest = iter->client;

		if (dest != sender) {
			write_req_t *req =
				(write_req_t *)xmalloc(sizeof(write_req_t));

			char *msg_copy = strdup(msg);
			req->buf = uv_buf_init(msg_copy, strlen(msg_copy));
			uv_write((uv_write_t *)req, dest, &req->buf, 1,
				 echo_write);
		}

		iter = iter->next;
	}
}

void echo_read(uv_stream_t *client, ssize_t nread, const uv_buf_t *buf)
{
	if (nread > 0) {
		cJSON *data_json = parse_json(buf->base, nread);

		if (data_json == NULL) {
			free(buf->base);
			return;
		}

		char *data_json_str = stringify_json(data_json);

		broadcast_message(client, data_json_str);

		free(data_json_str);
		cJSON_Delete(data_json);
		free(buf->base);
		return;
	}

	if (nread < 0) {
		if (nread != UV_EOF)
			fprintf(stderr, "Read error %s\n", uv_err_name(nread));
		uv_close((uv_handle_t *)client, on_close);
	}

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
		uv_read_start((uv_stream_t *)client, alloc_buffer, echo_read);
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
