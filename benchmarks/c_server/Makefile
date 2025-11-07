CC = gcc
CFLAGS = -Wall -Wextra -O2 -std=c11
TARGET = c_server
SOURCE = server.c

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCE)

clean:
	rm -f $(TARGET)

run: $(TARGET)
	./$(TARGET)

