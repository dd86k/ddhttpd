module ddhttpd.utils;

string escapeHtml(string text)
{
    import std.array : appender;
    auto result = appender!string;
    foreach (char c; text)
    {
        switch (c)
        {
            case '<':  result.put("&lt;");   break;
            case '>':  result.put("&gt;");   break;
            case '&':  result.put("&amp;");  break;
            case '"':  result.put("&quot;"); break;
            case '\'': result.put("&#39;");  break;
            default:   result.put(c);        break;
        }
    }
    return result.data;
}
unittest
{
    assert(escapeHtml("test<example>") == "test&lt;example&gt;");
}