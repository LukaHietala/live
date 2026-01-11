#ifndef UTILS_H
#define UTILS_H

#include <cjson/cJSON.h>
#include <sys/types.h>

void die(const char *err, ...);
void *xmalloc(size_t size);
void *xrealloc(void *ptr, size_t size);
cJSON *parse_json(const char *base, ssize_t nread);
char *stringify_json(const cJSON *json);

#endif
