Testing:

```bash
go test -v .
```

Benchmarking:

```bash
go test -bench=.
# Or with allocs too
go test -bench=. -benchmem
```

Events (unstable):

- `handshake`. Every client that dials to server, must do a "handshake" event that contains metadata of that client like name. Fields:
    - `name`. User's name that other clients see
- `request_files`. Send's request to host for filetree. No fields.
- `response_files`. If `request_files` is received, you must respond with list of file paths to server. Files should be recursively collected from the same place that editor was started in. Fields:
    - `files`. Filetree. Format should be like this: ["README.md", "path/file.hs"].
    - `request_id`. Added by server to resolve requests and to foward request to right client. This can be gotten from `request_files` event.
