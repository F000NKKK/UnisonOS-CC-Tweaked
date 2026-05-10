    UnisonOS Working Group                                       F. Project
    Request for Comments: 0001                                          2026
    Category: Standards Track
    Status:   Active



                  UnisonOS Agent-Era System Architecture


Status of This Memo

   This document specifies the system architecture of UnisonOS in its
   "Agent-Era" form (1.x).  Distribution of this memo is unlimited
   within the UnisonOS project.

Abstract

   This document defines the layered architecture in which a thin
   per-device "agent", a multiplexing "gateway", and arbitrary external
   "user code" cooperate over a single typed contract (gRPC).  It
   delineates responsibilities of each component, the shape of their
   interfaces, and the cross-cutting concerns of identity, isolation,
   and update.

   The wire protocol between the gateway and the agent is specified in
   [RFC-0002].  Migration from the previous package-manager-based
   system is specified in [RFC-0003].

Table of Contents

   1.  Introduction ................................................. 2
   
       1.1.  Requirements Language ................................... 2
	   
       1.2.  Terminology ............................................. 2
	   
   2.  Components ................................................... 3
   
       2.1.  Agent ................................................... 3
	   
       2.2.  Gateway ................................................. 3
	   
       2.3.  User Code ............................................... 4
	   
   3.  Identity and Isolation ....................................... 4
   
       3.1.  Device Identity ......................................... 4
	   
       3.2.  World Sharding .......................................... 4
	   
   4.  Authentication ............................................... 5
   
   5.  Code Update Path ............................................. 5
   
   6.  Failure Semantics ............................................ 5
   
   7.  Security Considerations ...................................... 6
   
   8.  References ................................................... 6


1.  Introduction

   UnisonOS replaces a previous design in which application code ran
   on the CC:Tweaked computer itself, distributed via a package
   manager ("upm"), with one in which the CC:Tweaked computer hosts
   only a minimal "agent" exposing the entirety of its Lua surface and
   its CC:Tweaked SDK to an external network endpoint.

   The intent is that all higher-level logic SHALL be implemented
   outside the simulated computer in the language and runtime of the
   operator's choice, calling into the simulated computer through a
   single typed gRPC contract.

1.1.  Requirements Language

   The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT",
   "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in
   this document are to be interpreted as described in [RFC2119].

1.2.  Terminology

   Agent       The Lua process running on a CC:Tweaked computer that
               opens an outbound WebSocket to the gateway and serves
               remote Lua calls.

   Gateway     A Node.js process exposing a public gRPC endpoint and
               an internal WebSocket bus.  It maintains a registry of
               attached agents and routes each gRPC call to the
               appropriate agent.

   User Code   Any process that opens a gRPC channel to the gateway
               and issues calls.  User Code is OUTSIDE the scope of
               this specification beyond conformance to the contract.

   World       A logical shard.  Two devices with the same numeric
               computer-id but different worlds MUST NOT see each
               other.

   Contract    The set of services and messages declared in
               'packages/proto/unison.proto', taken as the
               authoritative interface.


2.  Components

2.1.  Agent

   Each CC:Tweaked computer SHALL run exactly one agent process.  The
   agent's responsibilities are:

   o  Maintain an authenticated WebSocket connection to the gateway,
      reconnecting with exponential backoff on failure.

   o  Resolve any dotted Lua path (e.g., "turtle.forward",
      "peripheral.call") on its own '_ENV', invoke it via 'pcall'
      with caller-supplied arguments, and return all return-values to
      the gateway.

   o  Optionally run an 'os.pullEventRaw' loop and forward filtered
      events to the gateway when subscribed.

   o  Implement a small set of high-level helpers prefixed with two
      underscores ("__") for operations that have no single CC:Tweaked
      counterpart (file I/O round-trips, HTTP fetch with response
      capture, monitor drawing primitives).

   The agent MUST NOT contain any feature that depends on durable
   on-device state beyond its configuration file.  All persistent
   state is the gateway's or user code's concern.

2.2.  Gateway

   The gateway SHALL:

   o  Listen on a public gRPC endpoint (default TCP port 9290) and
      register every service declared in the contract.

   o  Listen on an internal WebSocket endpoint (default TCP port 9275)
      and accept agent connections after a JSON authentication frame.

   o  Maintain an in-memory registry keyed by '(world_id, device_id)'.

   o  For each gRPC call, locate the addressed agent, forward the
      call as a JSON-RPC frame, await a correlated reply within the
      caller-specified or default timeout, and translate the reply
      into the gRPC response.

   The gateway MUST NOT add behaviour beyond translation: each
   typed gRPC service is a thin shim around a 'LuaBridge.Call' to
   the agent at a fixed path with a fixed argument shape.  Domain
   logic is the responsibility of user code.

2.3.  User Code

   User code SHALL communicate with the gateway exclusively through
   gRPC as specified in the contract.  It MAY be implemented in any
   language for which a gRPC client exists.  Reference clients in
   TypeScript and Python are provided under 'packages/clients/'.


3.  Identity and Isolation

3.1.  Device Identity

   The agent identifies itself in its authentication frame with a
   string 'id' that defaults to 'tostring(os.getComputerID())'.
   Operators MAY override this with a stable name through the agent
   configuration file when human-readable identifiers are preferred.

3.2.  World Sharding

   Both the agent's authentication frame and every 'DeviceTarget' in
   the gRPC contract carry a 'world_id'.  The gateway SHALL key its
   registry and message correlation by '(world_id, device_id)' so that
   collisions across worlds are impossible.

   Where 'world_id' is omitted, the value "default" SHALL be assumed.


4.  Authentication

   A single shared bearer token MAY be configured.  When configured,
   the gateway:

   o  REQUIRES the token in the agent's authentication frame and
      closes the WebSocket otherwise.

   The gateway does NOT currently enforce authentication on its gRPC
   surface.  Operators SHOULD terminate gRPC traffic at a reverse
   proxy that performs mTLS or token validation when exposing the
   gateway beyond a trusted network.


5.  Code Update Path

   After 1.0.0 the agent does NOT poll any update channel.  Updates
   to agent code are delivered as gRPC calls from authorized user
   code, typically the sequence:

      Fs.WriteFile(target, "/unison/agent/init.lua", new_source)
      Os.Reboot(target)

   For runtime patches that do not require a reboot, 'LuaBridge.Eval'
   MAY be used.

   This path supersedes the manifest/checksum/staging mechanism used
   prior to 1.0.0.  See [RFC-0003] for the migration step.


6.  Failure Semantics

   o  An agent disconnect SHALL fail every in-flight call with an
      error.  The gateway re-accepts the agent on reconnect; in-flight
      gRPC calls are NOT replayed.

   o  A gRPC call to an unattached device SHALL return 'NOT_FOUND'
      (in the device-management surface) or a 'no agent attached'
      error in the typed surface.

   o  Per-call timeouts default to 10 s and MAY be overridden via
      'DeviceTarget.timeout_ms'.

   o  Returns of the form '[false, "reason"]' from CC APIs SHALL be
      translated into 'LuaResult { ok=false, error="reason" }'.


7.  Security Considerations

   o  The WebSocket bus carries raw 'fs', 'http', and 'eval'
      capabilities to a CC:Tweaked computer.  An attacker with the
      bearer token can write arbitrary files, execute arbitrary code,
      and reboot the device.  Treat the token as a root credential.

   o  The gRPC surface is currently unauthenticated.  An attacker
      with reachability to port 9290 can issue any call to any
      attached device.  Production deployments MUST restrict access
      at the network layer.

   o  'LuaBridge.Eval' executes arbitrary Lua on the agent.  It is
      provided deliberately and SHOULD NOT be exposed to untrusted
      user code paths even with authentication.


8.  References

   [RFC2119]   Bradner, S., "Key words for use in RFCs to Indicate
               Requirement Levels", BCP 14, RFC 2119, March 1997.

   [RFC-0002]  UnisonOS Working Group, "UnisonOS Wire Protocol
               (Gateway-Agent)".

   [RFC-0003]  UnisonOS Working Group, "UnisonOS Migration to
               Agent-Era 1.0.0".
