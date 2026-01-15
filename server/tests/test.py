import socket
import time

def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('127.0.0.1', 8080))

    # Test 1: Multiple messages
    print("Test multiple messages...")
    s.sendall(b"msg1\nmsg2\nmsg3\n")
    input()

    # Test 2: Fragmented message
    print("Test fragmented message...")
    s.sendall(b"partia")
    input()
    s.sendall(b"l message\n")

    # Test 3: Large message
    print("Test large message...")
    large_msg = b"A" * 50000 + b"\n"
    s.sendall(large_msg)
    input()

    # Test 4: Send too large message < 10 MB
    print("Test too large message (expect to fail)")
    too_large_msg = b"A" * 500000000 + b"\n"
    s.sendall(too_large_msg)
    input()

    s.close()

if __name__ == "__main__":
    main()
