#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "utils.h"

/* Parses JSON from string. Must be freed */
cJSON *parse_json(const char *base, ssize_t nread)
{
	if (nread <= 0)
		return NULL;

	char *data = xmalloc(nread + 1);
	if (!data)
		return NULL;

	memcpy(data, base, nread);
	data[nread] = '\0';

	cJSON *json = cJSON_Parse(data);

	if (json == NULL)
		return NULL;

	free(data);
	return json;
}

/* Returns unformatted JSON string with newline. Must be freed */
char *stringify_json(const cJSON *json)
{
	char *raw = cJSON_PrintUnformatted(json);
	if (raw == NULL)
		return NULL;

	size_t len = strlen(raw);

	char *resized = (char *)realloc(raw, len + 2);

	if (resized == NULL) {
		cJSON_free(raw);
		return NULL;
	}

	resized[len] = '\n';
	resized[len + 1] = '\0';

	return resized;
}

void die(const char *err, ...)
{
	char msg[4096];
	va_list params;
	va_start(params, err);
	vsnprintf(msg, sizeof(msg), err, params);
	fprintf(stderr, "%s\n", msg);
	va_end(params);
	exit(1);
}

void *xmalloc(size_t size)
{
	void *ptr = malloc(size);
	if (ptr == NULL && size > 0)
		die("Out of memory (malloc failed for %zu bytes)\n", size);
	return ptr;
}

void *xrealloc(void *ptr, size_t size)
{
	void *new_ptr = realloc(ptr, size);
	if (new_ptr == NULL && size > 0)
		die("Out of memory (realloc failed for %zu bytes)\n", size);
	return new_ptr;
}

/* Initialize a circular buffer */
void cb_init(struct circular_buffer *cb, size_t size)
{
	cb->size = size;
	cb->amount = 0;
	cb->buffer = (char *)xmalloc(cb->size);
	cb->buffer_end = cb->buffer + cb->size;
	cb->head = cb->buffer;
	cb->tail = cb->buffer;
	cb->tmp = NULL;
}

/* Free the memory held by a circular buffer */
void cb_free(struct circular_buffer *cb)
{
	free(cb->buffer);
	cb->buffer = NULL;
	cb->buffer_end = NULL;
	cb->tail = NULL;
	cb->head = NULL;
}

/* Copy data_len bytes to the head of the buffer, head
 * to the end of the newly allocated portion of memory. */
void cb_push_data(struct circular_buffer *cb, char* data, size_t data_len)
{
	cb->amount += data_len;
	/* If data loops over the end */
	if (cb->head + data_len > cb->buffer_end) {
		/* Copy the two portions seperately */
		/* First portion from the head to the end of the buffer */
		const size_t first_portion = cb->buffer_end - cb->head;
		/* Second portion from the beginning of the buffer to the
		 * rest of the data amount */
		const size_t second_portion = data_len - first_portion;
		/* Copy memory */
		memcpy(cb->head, data, first_portion);
		memcpy(cb->buffer, data + first_portion, second_portion);
		/* Move pointers */
		cb->head = cb->buffer + second_portion;
	} else {
		/* Directly copy data */
		memcpy(cb->head, data, data_len);
		cb->head += data_len;
	}
}

/* Return a usable c-string from the tail, and tail to the beginning
 * of the next possible string */
char* cb_get_string(struct circular_buffer *cb)
{
	/* If string wraps over loop */
	if (cb->tail > cb->head) {
		/* We can't directly pass the tail
		 * forward, since it wouldn't be
		 * a valid string here */

		/* First portion from the tail to the end of the buffer */
		const size_t first_portion = cb->buffer_end - cb->tail;
		/* Second portion from the beginning of the buffer to head */
		const char* newline_pos = memchr(cb->buffer, '\n', cb->head - cb->buffer);
		if (!newline_pos)
			return NULL;
		const size_t second_portion = newline_pos - cb->buffer + 1;
		cb->tmp = xmalloc(first_portion + second_portion);
		/* Copy the string to the newly allocated memory */
		memcpy(cb->tmp, cb->tail, first_portion);
		/* Second portion */
		memcpy(cb->tmp + first_portion, cb->buffer, second_portion);
		/* null-terminator */
		*(cb->tmp + first_portion + second_portion - 1) = '\0';
		/* Move tail past to the beginning of the next string */
		cb->tail = (char *)newline_pos + 1;
		/* Negate counter */
		cb->amount -= first_portion + second_portion;
		return cb->tmp;
	} else {
		/* Convert \n to \0 */
		char* ptr = memchr(cb->tail, '\n', cb->head - cb->tail);
		if (ptr) {
			*ptr = '\0';
			/* String to return */
			char* str = cb->tail;
			/* Negate counter */
			cb->amount -= ptr - str + 1;
			/* Move tail past the end of the string so next time
			 * cb_get_string is called, it will return a different
			 * string, if it finds one before the header.
			 * (before the head, because if that clause wasn't present,
			 * it would read old strings from the buffer) */
			cb->tail = ptr+1;
			return str;
		}
		return NULL;
	}
}

/* Reallocate the memory of the buffer */
void cb_realloc(struct circular_buffer *cb, size_t new_size)
{
	/* No error checking since it will be check manually
	 * when this function is called */
	/* Remember offset */
	const size_t head_offset = cb->head - cb->buffer;
	const size_t tail_offset = cb->tail - cb->buffer;
	/* Reallocated */
	cb->buffer = realloc(cb->buffer, new_size);
	/* Correct pointers */
	cb->buffer_end = cb->buffer + new_size;
	cb->size = new_size;
	cb->head = cb->buffer + head_offset;
	cb->tail = cb->buffer + tail_offset;
}

void cb_clean_string(struct circular_buffer *cb)
{
	/* Free temporary memory */
	if (cb->tmp) {
		free(cb->tmp);
		cb->tmp = NULL;
	} else {
		/* Convert \0 to \n */
		char* ptr = cb->tail - 1;
		if (*ptr == '\0')
			*ptr = '\n';
		else
			die("Unable to clean string");
	}
}

