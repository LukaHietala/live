Make sure to have libuv and cJSON development headers installed. Once installed, compile with `make` and run it from build directory.

The easiest way to test is by using [GNU Netcat](https://netcat.sourceforge.net/).

### List of valid events

- `request_files` - (client) Sends a request to host and host needs to respond with `response_files` event that contains all relative directory entries.
```json
{"event":"request_files", "to_host":true}
```
- `response_files` - (host) Responds to `request_files` with all relative directory entries.
```json
{"event":"response_files", "entries": ["root/path/file.txt"], "to_client": "<request_files:from_id>", "request_id": "<request_files:request_id>"}
```
