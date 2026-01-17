# ddhttpd

Minimalistic Web server using libmicrohttpd.

Made in a hastily fashion, do not expect quality.

Why?
- vibe-http is too heavy (compile-time)
- vibe-http does not work with gdc
- I like mhd's daemon function, lets me do other things

You'll need microhttpd dynamic library packages, like `libmicrohttpd12` or `libmicrohttpd12t64` (Ubuntu package).

License: BSL-1.0