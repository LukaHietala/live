CC = gcc
CFLAGS += -Wall -Wextra -O2 -g
CFLAGS += $(shell pkg-config --cflags libuv)
LDLIBS += $(shell pkg-config --libs libuv)
TARGET = build/server
SRC = main.c

all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)
	@echo "Ready: $(TARGET)"

clean:
	rm -rf $(dir $(TARGET))

.PHONY: all clean
