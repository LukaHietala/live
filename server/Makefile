CC = gcc
CFLAGS += -Wall -Wextra -O2 -g
CFLAGS += $(shell pkg-config --cflags libuv libcjson)
LDLIBS += $(shell pkg-config --libs libuv libcjson)

BUILD_DIR = build
TARGET = $(BUILD_DIR)/server

SRCS = $(wildcard src/*.c)
OBJS = $(SRCS:src/%.c=$(BUILD_DIR)/%.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(OBJS) -o $(TARGET) $(LDLIBS)
	@echo "Ready: $(TARGET)"

$(BUILD_DIR)/%.o: src/%.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD_DIR)
