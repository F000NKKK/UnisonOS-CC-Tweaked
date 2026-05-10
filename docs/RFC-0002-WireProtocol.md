    UnisonOS Working Group                                       F. Project
    Request for Comments: 0002                                          2026
    Category: Standards Track
    Status:   Active



             UnisonOS Wire Protocol (Gateway-Agent Bus)


Status of This Memo

   This document specifies the framing and message semantics of the
   WebSocket-based bus that connects a UnisonOS agent to a UnisonOS
   gateway.  Distribution of this memo is unlimited within the
   UnisonOS project.

Abstract

   This document defines the message types, framing, correlation, and
   error semantics of the bus described informally in [RFC-0001],
   Section 2.  The bus is intentionally simple: one TCP connection per
   agent, JSON-encoded text frames, one in-flight pending-call table
   keyed by client-supplied identifiers.

Table of Contents

   1.  Introduction ................................................. 2
   
       1.1.  Requirements Language ................................... 2
	   
   2.  Transport .................................................... 2
   
   3.  Framing and Encoding ......................................... 3
   
   4.  Authentication Frame ......................................... 3
   
   5.  Gateway-to-Agent Messages .................................... 4
   
       5.1.  call .................................................... 4
	   
       5.2.  eval .................................................... 4
	   
       5.3.  subscribe ............................................... 5
	   
       5.4.  unsubscribe ............................................. 5
	   
       5.5.  queue_event ............................................. 5
	   
   6.  Agent-to-Gateway Messages .................................... 5
   
       6.1.  result .................................................. 5
	   
       6.2.  error ................................................... 6
	   
       6.3.  event ................................................... 6
	   
       6.4.  heartbeat ............................................... 6
	   
   7.  Reserved Path Prefix "__" .................................... 6
   
   8.  Correlation and Timeouts ..................................... 7
   
   9.  Disconnect and Reconnect ..................................... 7
   
   10. Compatibility and Versioning ................................. 8
   
   11. References ................................................... 8


1.  Introduction

   The bus described herein carries the calls produced by the
   gateway's gRPC service implementations to the agent process running
   on a CC:Tweaked computer, and the asynchronous events produced by
   that computer back to the gateway.

1.1.  Requirements Language

   The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT",
   "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in
   this document are to be interpreted as described in [RFC2119].


2.  Transport

   The transport SHALL be a WebSocket connection [RFC6455] initiated
   by the agent toward the gateway.  Both 'ws://' and 'wss://' schemes
   are supported.  TLS termination MAY occur at the gateway or at a
   reverse proxy in front of it.

   The agent MUST tolerate idle connections and SHOULD send a
   'heartbeat' frame every 15 s in the absence of other traffic.

   The gateway MUST treat any frame whose JSON cannot be parsed as a
   protocol violation and close the connection with WebSocket close
   code 4002.


3.  Framing and Encoding

   Each WebSocket text frame SHALL contain exactly one JSON object.
   Binary frames are NOT used.  The encoding is UTF-8.

   Field types MUST be those declared below.  Unknown fields MUST be
   ignored by the receiver.  Numbers fitting in IEEE-754 double
   precision MAY be used directly; values requiring 64-bit integer
   precision MUST be transmitted as decimal strings.


4.  Authentication Frame

   The first frame from the agent to the gateway MUST be of type
   'auth':

       { "type":         "auth",
         "id":           <string>,
         "world_id":     <string>,
         "token":        <string>,
         "role":         "turtle" | "computer" | "pocket",
         "label":        <string>,
         "version":      <string>,
         "capabilities": [ <string>, ... ] }

   On success the gateway SHALL reply with:

       { "type": "ready" }

   The gateway SHALL close the connection with a non-1000 close code
   when authentication fails:

       4001  authentication frame did not arrive within 10 s
       4002  malformed JSON
       4003  first frame was not 'auth'
       4004  token mismatch
       4005  empty 'id'


5.  Gateway-to-Agent Messages

5.1.  call

       { "id":   <string>,
         "type": "call",
         "path": <dotted Lua path>,
         "args": [ <Lua-plain>, ... ] }

   The agent MUST resolve 'path' as successive table indexes on
   '_ENV', stopping at the first 'nil' result.  If the resolved value
   is not a function, the agent SHALL reply with 'error' carrying
   'unknown path: <path>'.

   Otherwise the agent SHALL invoke the function via 'pcall' with the
   provided arguments.  All return-values SHALL be packed into the
   'values' array of the 'result' reply.

5.2.  eval

       { "id":     <string>,
         "type":   "eval",
         "source": <string>,
         "env":    { <name>: <Lua-plain>, ... } }

   The agent MUST compile 'source' with 'load' in mode "t" using
   '_ENV' (optionally augmented by 'env') and execute it via 'pcall'.
   The return-values SHALL be returned in the 'result' reply.

5.3.  subscribe

       { "id":     <string>,
         "type":   "subscribe",
         "events": [ <string>, ... ] }

   The agent SHALL begin or continue forwarding 'event' frames whose
   first value matches one of the listed event types.  An empty
   'events' array means "all".  No reply is sent.

5.4.  unsubscribe

       { "id": <string>, "type": "unsubscribe" }

   The agent SHALL stop forwarding events.  No reply is sent.

5.5.  queue_event

       { "id":   <string>,
         "type": "queue_event",
         "event": <string>,
         "args":  [ <Lua-plain>, ... ] }

   The agent SHALL invoke 'os.queueEvent(event, table.unpack(args))'.
   No reply is sent.


6.  Agent-to-Gateway Messages

6.1.  result

       { "id":     <string>,
         "type":   "result",
         "values": [ <Lua-plain>, ... ] }

   Sent in response to 'call' or 'eval' when 'pcall' returned true.

6.2.  error

       { "id":    <string>,
         "type":  "error",
         "error": <string> }

   Sent in response to 'call' or 'eval' when 'pcall' returned false,
   when the path could not be resolved, or when 'load' failed.

6.3.  event

       { "type":  "event",
         "event": <string>,
         "args":  [ <Lua-plain>, ... ],
         "ts":    <epoch-millis> }

   Unsolicited; sent only while a subscription is active.

6.4.  heartbeat

       { "type":    "heartbeat",
         "metrics": <object> }

   The agent MAY include any JSON-encodable metrics object.  The
   gateway SHALL update 'last_seen' for the device on receipt.


7.  Reserved Path Prefix "__"

   Paths beginning with two underscore characters SHALL NOT be
   resolved against '_ENV'.  They are reserved for high-level
   operations implemented inside the agent itself.  The current set
   is:

       __readFile     (path)               -> string | nil
       __writeFile    (path, data)         -> true | false, error
       __appendFile   (path, data)         -> true | false, error
       __httpFetch    (req-table)          -> response-table
       __display.clear  (monitor, bg)
       __display.text   (monitor, x, y, text, fg, bg, scale)
       __display.bar    (monitor, x, y, w, fraction, fill, empty, label)
       __display.chart  (monitor, x, y, w, h, values, line, bg, min, max)

   New helpers MAY be added in a backward-compatible manner; new
   prefix names MAY NOT collide with existing or future Lua globals.


8.  Correlation and Timeouts

   The 'id' field of 'call', 'eval', 'subscribe', 'unsubscribe', and
   'queue_event' messages is opaque to the agent and SHALL be echoed
   verbatim in any reply.  Identifiers SHOULD be unique within a
   single connection; the gateway's reference implementation generates
   them as '<base36 millis>-<base36 sequence>'.

   The gateway SHALL fail any pending call whose reply does not arrive
   within the per-call timeout, removing the entry from its
   correlation table.  The agent's eventual late reply, if any, MUST
   be discarded silently by the gateway.


9.  Disconnect and Reconnect

   On WebSocket close from either side the gateway SHALL fail every
   pending call for the affected device with a 'agent disconnected'
   error and remove the device from its registry.

   The agent SHALL attempt reconnection with exponential backoff
   bounded at 60 s.  After a successful reconnect, in-flight calls
   from the previous session are NOT replayed.

   gRPC streams of type 'Events.Subscribe' opened by user code remain
   open across agent reconnects, but receive nothing while the agent
   is disconnected.


10.  Compatibility and Versioning

   This protocol is intentionally not versioned at the wire level.
   New message types, fields, and "__" helpers MAY be added freely
   provided existing producers and consumers continue to ignore
   unknown fields and unknown types.

   Breaking changes (renaming or removing a message type, changing
   the meaning of an existing field) SHALL be made by introducing a
   new path or message type and deprecating the old.


11.  References

   [RFC2119]  Bradner, S., "Key words for use in RFCs to Indicate
              Requirement Levels", BCP 14, RFC 2119, March 1997.

   [RFC6455]  Fette, I. and A. Melnikov, "The WebSocket Protocol",
              RFC 6455, December 2011.

   [RFC-0001] UnisonOS Working Group, "UnisonOS Agent-Era System
              Architecture".
