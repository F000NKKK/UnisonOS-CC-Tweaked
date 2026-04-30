-- Backwards-compat forwarder: shell commands historically did
-- dofile("/unison/shell/path.lua"). Real implementation lives in
-- /unison/lib/path.lua now so apps can also use it.
return dofile("/unison/lib/path.lua")
