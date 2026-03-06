# ddhttpd

ddhttpd is a minimalistic lightweight HTTP daemon library using libmicrohttpd.

Why?
- vibe-http is too heavy (compile-time)
- vibe-http does not work with gdc
- I like mhd's daemon function, lets me do other things

## Dependencies

You'll need microhttpd dynamic library packages, like `libmicrohttpd12` or `libmicrohttpd12t64` (Ubuntu package).

For the static library, you will need `libmicrohttpd-dev` (Ubuntu package).

## Static binding

By default, ddhttpd loads libmicrohttpd dynamically at runtime. To link against
libmicrohttpd statically (at compile time) instead, use the `static-binding`
configuration:

```bash
dub build -c static-binding
```

Or in a consuming project's `dub.sdl`:
```
subConfiguration "ddhttpd" "static-binding"
```

This sets `BindBC_Static` and links against `-lmicrohttpd`, so you will need the
development package installed (e.g. `libmicrohttpd-dev` on Ubuntu).

## License

BSL-1.0