#ifndef UTILS_H
#define UTILS_H

#include <cjson/cJSON.h>
#include <sys/types.h>

void die(const char *err, ...);
void *xmalloc(size_t size);
void *xrealloc(void *ptr, size_t size);
cJSON *parse_json(const char *base, ssize_t nread);
char *stringify_json(const cJSON *json);

/* Circular overwriting string buffer to store streams */
struct circular_buffer {
	/* Actual data array */
	char* buffer;
	/* Pointer to the end of the buffer */
	char* buffer_end;
	/* How large the buffer is */
	size_t size;
	/* Pointer to the head of the buffer (where data is inserted)
	 * head will always point exactly where new data will start
	 * being inserted, and after insertion will move forward */
	char* head;
	/* Pointer to the tail of the buffer (where data is read)
	 * tail will always point exactly after the last string that
	 * was read, and it will attempt to find a new string when
	 * cb_get_string is called */
	char* tail;
	/* When a string is read that overlaps the edge,
	 * it must temporarily be stored in some memory,
	 * to be properly read by other functions */
	char* tmp;
	/* The amount of unread data currently held */
	size_t amount;
};

void cb_init(struct circular_buffer *cb, size_t size);
void cb_free(struct circular_buffer *cb);
void cb_push_data(struct circular_buffer *cb, char* data, size_t data_len);
char* cb_get_string(struct circular_buffer *cb);
void cb_realloc(struct circular_buffer *cb, size_t new_size);
void cb_clean_string(struct circular_buffer *cb);
#endif
