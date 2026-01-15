import socket
import json
import time

# Total amount of messages
TOTAL_MESSAGES = 100000
# Number of messages in a single payload
BATCH_SIZE = 10000

def main():
    msg_str = json.dumps({"msg": "mirri" * 200}) + "\n"
    payload = msg_str.encode('utf-8') * BATCH_SIZE

    print(f"Sending {TOTAL_MESSAGES} messages, per message lenght: {len(msg_str)} bytes")

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.connect(("127.0.0.1", 8080))

        start_time = time.perf_counter()

        for _ in range(TOTAL_MESSAGES // BATCH_SIZE):
            s.sendall(payload)

        duration = time.perf_counter() - start_time

        print("\nResults:")
        print(f"Total Time:   {duration:.4f} seconds")
        print(f"Messages/sec: {TOTAL_MESSAGES / duration:.0f}")

    except Exception as e:
        print(e)
    finally:
        s.close()

if __name__ == "__main__":
    main()

