module ddhttpd.websocket;

import bindbc.libmicrohttpd;
import core.memory : GC;
import core.thread.osthread : Thread, thread_attachThis;

/// WebSocket frame opcodes per RFC 6455.
enum WSOpcode : ubyte
{
    continuation = 0x0,
    text         = 0x1,
    binary       = 0x2,
    close        = 0x8,
    ping         = 0x9,
    pong         = 0xA,
}

/// A received WebSocket message, assembled from one or more frames.
struct WSMessage
{
    WSOpcode opcode;
    ubyte[]  data;

    /// Payload as a UTF-8 string. Only meaningful when opcode == text.
    string text() const @property { return cast(string)data; }
}

/// A live WebSocket connection passed to a registered handler.
/// Pings are answered automatically; pongs are silently dropped.
struct WebSocketConnection
{
    /// Send a text message.
    void sendText(string payload)
    {
        send_frame(WSOpcode.text, cast(const(ubyte)[])payload);
    }

    /// Send a binary message.
    void sendBinary(const(ubyte)[] payload)
    {
        send_frame(WSOpcode.binary, payload);
    }

    /// Send a ping frame.
    void sendPing(const(ubyte)[] payload = null)
    {
        send_frame(WSOpcode.ping, payload);
    }

    /// Send a close frame and mark the connection closed on this side.
    void close(ushort code = 1000, string reason = "")
    {
        if (closed) return;
        closed = true;

        ubyte[125] buf = void; // control frames are capped at 125 bytes
        buf[0] = cast(ubyte)(code >> 8);
        buf[1] = cast(ubyte)(code & 0xFF);
        size_t rlen = reason.length > 123 ? 123 : reason.length;
        buf[2 .. 2 + rlen] = cast(const(ubyte)[])reason[0 .. rlen];
        send_frame(WSOpcode.close, buf[0 .. 2 + rlen]);
    }

    /// Block until the next application message arrives.
    /// Returns text, binary, or close frames. Handles pings internally.
    WSMessage receive()
    {
        ubyte[]  frag_payload;
        WSOpcode frag_opcode;

        while (true)
        {
            WSFrame f = recv_frame();

            switch (f.opcode)
            {
                case WSOpcode.ping:
                    send_frame(WSOpcode.pong, f.payload);
                    continue;

                case WSOpcode.pong:
                    continue;

                case WSOpcode.close:
                    if (!closed)
                    {
                        closed = true;
                        send_frame(WSOpcode.close, f.payload);
                    }
                    return WSMessage(WSOpcode.close, f.payload);

                case WSOpcode.continuation:
                    frag_payload ~= f.payload;
                    if (f.fin)
                        return WSMessage(frag_opcode, frag_payload);
                    continue;

                default: // text or binary
                    if (f.fin)
                        return WSMessage(f.opcode, f.payload);
                    frag_opcode  = f.opcode;
                    frag_payload = f.payload;
                    continue;
            }
        }
    }

    bool isClosed() const @property { return closed; }

    /// URL parameters extracted from a pattern route (e.g. /ws/:id → params["id"]).
    string[string] params;

package(ddhttpd):
    this(MHD_socket sock_, MHD_UpgradeResponseHandle *urh_, const(ubyte)[] extra)
    {
        sock = sock_;
        urh  = urh_;
        if (extra.length)
            pending = extra.dup;
    }

private:
    MHD_socket                 sock;
    MHD_UpgradeResponseHandle *urh;
    ubyte[]                    pending; // data pre-buffered by MHD before the upgrade
    bool                       closed;

    private struct WSFrame
    {
        bool     fin;
        WSOpcode opcode;
        ubyte[]  payload;
    }

    void send_frame(WSOpcode opcode, const(ubyte)[] payload)
    {
        ubyte[10] hdr = void;
        size_t hlen;

        hdr[0] = 0x80 | cast(ubyte)opcode; // FIN=1, no RSV bits

        ulong len = payload.length;
        if (len < 126)
        {
            hdr[1] = cast(ubyte)len;
            hlen   = 2;
        }
        else if (len <= 0xFFFF)
        {
            hdr[1] = 126;
            hdr[2] = cast(ubyte)(len >> 8);
            hdr[3] = cast(ubyte)(len & 0xFF);
            hlen   = 4;
        }
        else
        {
            hdr[1] = 127;
            foreach (i; 0 .. 8)
                hdr[2 + i] = cast(ubyte)(len >> (56 - i * 8));
            hlen = 10;
        }

        send_all(hdr[0 .. hlen]);
        if (payload.length)
            send_all(payload);
    }

    WSFrame recv_frame()
    {
        ubyte[2] hdr;
        recv_exact(hdr[]);

        bool     fin    = (hdr[0] & 0x80) != 0;
        WSOpcode opcode = cast(WSOpcode)(hdr[0] & 0x0F);
        bool     masked = (hdr[1] & 0x80) != 0;
        ulong    plen   = hdr[1] & 0x7F;

        if (plen == 126)
        {
            ubyte[2] ext;
            recv_exact(ext[]);
            plen = (cast(ulong)ext[0] << 8) | ext[1];
        }
        else if (plen == 127)
        {
            ubyte[8] ext;
            recv_exact(ext[]);
            plen = 0;
            foreach (b; ext) plen = (plen << 8) | b;
        }

        ubyte[4] mask = void;
        if (masked) recv_exact(mask[]);

        ubyte[] payload = new ubyte[](cast(size_t)plen);
        recv_exact(payload);

        if (masked)
            foreach (i, ref b; payload) b ^= mask[i & 3];

        return WSFrame(fin, opcode, payload);
    }

    void recv_exact(ubyte[] buf)
    {
        import core.sys.posix.sys.socket : recv;

        size_t off;

        if (pending.length)
        {
            size_t take = pending.length < buf.length ? pending.length : buf.length;
            buf[0 .. take] = pending[0 .. take];
            pending        = pending[take .. $];
            off            = take;
        }

        while (off < buf.length)
        {
            ptrdiff_t n = recv(sock, buf.ptr + off, buf.length - off, 0);
            if (n <= 0)
                throw new Exception("WebSocket connection lost");
            off += cast(size_t)n;
        }
    }

    void send_all(const(ubyte)[] data)
    {
        import core.sys.posix.sys.socket : send;

        version (linux)
            enum int sendFlags = 0x4000; // MSG_NOSIGNAL
        else
            enum int sendFlags = 0;

        size_t off;
        while (off < data.length)
        {
            ptrdiff_t n = send(sock, data.ptr + off, data.length - off, sendFlags);
            if (n <= 0)
                throw new Exception("WebSocket send failed");
            off += cast(size_t)n;
        }
    }
}

/// Compute the Sec-WebSocket-Accept value from the client's key (RFC 6455 §4.2.2).
package(ddhttpd) string ws_compute_accept(string key)
{
    import std.digest.sha : sha1Of;
    import std.base64 : Base64;

    ubyte[20] hash = sha1Of(key ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    return Base64.encode(hash);
}

package(ddhttpd) struct WSUpgradeClosure
{
    void delegate(WebSocketConnection) handler;
    string[string] params;
}

extern(C) package(ddhttpd) void ws_upgrade_callback(
    void *cls,
    MHD_Connection *connection,
    void *req_cls,
    const(char) *extra_in,
    size_t extra_in_size,
    MHD_socket sock,
    MHD_UpgradeResponseHandle *urh)
{
    if (Thread.getThis() is null)
        thread_attachThis();

    // Copy before returning — extra_in may point into MHD's stack frame.
    ubyte[] extra = extra_in_size > 0
        ? (cast(ubyte*)extra_in)[0 .. extra_in_size].dup
        : null;

    WSUpgradeClosure *cl = cast(WSUpgradeClosure*)cls;

    Thread t = new Thread({
        if (Thread.getThis() is null)
            thread_attachThis();

        scope(exit)
        {
            MHD_upgrade_action(urh, MHD_UPGRADE_ACTION_CLOSE);
            GC.removeRoot(cls);
        }

        try
        {
            WebSocketConnection conn = WebSocketConnection(sock, urh, extra);
            conn.params = cl.params;
            cl.handler(conn);
        }
        catch (Exception) {}
    });
    t.isDaemon = true;

    try
        t.start();
    catch (Exception)
    {
        MHD_upgrade_action(urh, MHD_UPGRADE_ACTION_CLOSE);
        GC.removeRoot(cls);
    }
}

unittest
{
    // RFC 6455 §1.3 handshake test vector
    assert(ws_compute_accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}
