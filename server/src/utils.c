#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "utils.h"

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

	if (json == NULL) {
		const char *err = cJSON_GetErrorPtr();
		if (err != NULL)
			fprintf(stderr, "Failed to parse json: %s\n", err);
	}

	free(data);
	return json;
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
