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
