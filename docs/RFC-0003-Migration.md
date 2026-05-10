    UnisonOS Working Group                                       F. Project
    Request for Comments: 0003                                          2026
    Category: Operations
    Status:   Active



              UnisonOS Migration to Agent-Era 1.0.0


Status of This Memo

   This document specifies the one-time migration procedure that
   converts a UnisonOS deployment running pre-1.0.0 (package-manager
   based) into the Agent-Era topology described in [RFC-0001].

Abstract

   The migration is delivered as a single release 1.0.0 published
   through the existing manifest-driven update mechanism (henceforth
   "upm").  After 1.0.0 is applied, upm SHALL be considered retired
   and SHALL NOT issue further releases.

   This document specifies the on-device sequence executed by 1.0.0,
   the operator's preconditions and postconditions, and the failure
   modes that operators MUST anticipate.

Table of Contents

   1.  Introduction ................................................. 2
   
       1.1.  Requirements Language ................................... 2
	   
   2.  Preconditions ................................................ 2
   
   3.  The 1.0.0 Release ............................................ 3
   
       3.1.  Manifest Contents ....................................... 3
	   
       3.2.  Hijacker boot.lua ....................................... 3
	   
   4.  On-Device Sequence ........................................... 4
   
   5.  Operator Procedure ........................................... 5
   
   6.  Postconditions ............................................... 5
   
   7.  Failure Modes ................................................ 6
   
   8.  Retirement of upm ............................................ 6
   
   9.  References ................................................... 7


1.  Introduction

   Pre-1.0.0 UnisonOS devices fetch a 'manifest.json' from a configured
   source URL, compare its 'version' field to the local
   '/unison/.version', and stage any new files into '/unison.staging/'
   before committing them at next boot.

   Release 1.0.0 weaponises this mechanism to deliver and install a
   thin agent (per [RFC-0001]) and remove every other component of
   the previous system.

1.1.  Requirements Language

   The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT",
   "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in
   this document are to be interpreted as described in [RFC2119].


2.  Preconditions

   o  The device's 'os_updater' service MUST be configured to fetch
      'manifest.json' from a source the operator controls (typically
      'raw.githubusercontent.com/.../master/manifest.json' or a
      private mirror).

   o  The operator MUST have published the 1.0.0 'manifest.json' and
      every file it lists at that source.

   o  A reachable gateway endpoint per [RFC-0001] MUST exist before
      1.0.0 finishes; otherwise devices will boot into a non-fatal
      "no gateway" reconnect loop.


3.  The 1.0.0 Release

3.1.  Manifest Contents

   The 1.0.0 'manifest.json' lists, under 'roles.common', exactly
   the following four files:

       unison/boot.lua
       unison/agent/init.lua
       unison/agent/display.lua
       unison/agent/config.lua.example

   Per-role file lists ('roles.computer', 'roles.turtle', etc.) are
   empty arrays.  This is essential: pre-1.0.0 boot logic deletes any
   existing file under '/unison/' that is not in the keep set
   ('common' + role-specific) and is not in the safe-paths exemption
   list.  Restricting the keep set to the four files above causes the
   entire pre-1.0.0 system tree to be removed in place.

3.2.  Hijacker boot.lua

   The 'unison/boot.lua' shipped in 1.0.0 ("the hijacker") performs
   the following actions on first execution:

       (1) Write '/startup.lua' containing
           'shell.run("/unison/agent/init.lua")'.

       (2) Copy '/unison/agent/config.lua.example' to
           '/unison/agent/config.lua' if no config file exists.

       (3) Delete residual paths that the pre-1.0.0 commit step would
           have left behind ('/unison.staging', '/unison/state',
           '/unison/logs', '/unison/apps', '/unison/.version', etc.).

       (4) Delete itself ('/unison/boot.lua').

       (5) Reboot.

   The hijacker performs no networking and depends only on
   CC:Tweaked globals.


4.  On-Device Sequence

   The complete sequence executed on a pre-1.0.0 device is:

       T0  Operator publishes 1.0.0 manifest and files.
       T1  os_updater polls source, observes
             manifest.version != local .version.
       T2  os_updater stages four files into '/unison.staging/' and
             writes '/unison/.pending-commit'.
       T3  Device reboots.
       T4  pre-1.0.0 boot.lua observes the marker, computes the keep
             set, deletes every non-safe path under '/unison/' that
             is not in the keep set (which here is exactly the four
             1.0.0 files), commits the staged files, writes the new
             '/unison/.version', removes the marker, and reboots.
       T5  Device boots: the hijacker '/unison/boot.lua' executes its
             five steps and reboots.
       T6  Device boots: '/startup.lua' starts the agent.  If
             '/unison/agent/config.lua' was the unedited template, the
             agent prints "edit config" and retries the connection.

   At T6 the device is in the Agent-Era steady state.


5.  Operator Procedure

   The operator MUST:

       (1) Verify '/unison/agent/config.lua.example' carries the
           gateway URL appropriate for the operator's deployment.

           Operators with multiple environments SHOULD prepare
           per-environment manifests rather than a single shared one.

       (2) Publish the 1.0.0 manifest and files to every source URL
           that the deployed fleet may consult.

       (3) Bring up the gateway (see [RFC-0001], Section 2.2).

       (4) Wait for devices to migrate.  The operator MAY accelerate
           by issuing 'os.reboot()' from a privileged channel.

       (5) Configure each device's '/unison/agent/config.lua' with
           the gateway URL, world id, and shared bearer token.  This
           step MAY be performed in advance by including a
           pre-populated 'config.lua' in 'roles.common'; doing so is
           OPTIONAL but RECOMMENDED for fleets above ~10 devices.


6.  Postconditions

   After successful migration:

   o  '/unison/' on the device contains exactly:
        unison/agent/init.lua
        unison/agent/display.lua
        unison/agent/config.lua.example
        unison/agent/config.lua
      and no other files.

   o  '/startup.lua' starts the agent on every boot.

   o  No 'os_updater', no 'pm', no 'manifest.json' polling occurs.

   o  '/unison/.version' is absent; version reporting is the
      responsibility of the agent's authentication frame.


7.  Failure Modes

   F1.  Network failure between T2 and T3.
        os_updater discards an incomplete staging directory on next
        attempt; no harm done.

   F2.  Power loss between T3 and T5.
        Pre-1.0.0 boot logic is re-entrant: it sees pending-commit on
        next boot and retries.  The hijacker is similarly re-entrant
        (its operations are idempotent).

   F3.  Power loss after the hijacker has deleted itself but before
        reboot.
        '/startup.lua' is already in place; the next boot proceeds to
        the agent directly.  No corruption.

   F4.  Gateway unreachable at T6.
        The agent retries with exponential backoff bounded at 60 s.
        No on-device intervention is required when the gateway is
        eventually brought up.

   F5.  Agent config file present but malformed.
        The agent halts at startup with an explanatory message and
        does NOT loop.  Operator MUST repair the file and reboot.

   F6.  Operator misconfigured 'roles.common' to include any
        pre-1.0.0 file.
        Migration succeeds but leaves the named file behind.  Recover
        by re-publishing a corrected manifest with the same version
        number plus a hash bump and rebooting affected devices, or by
        deleting the file via gateway.


8.  Retirement of upm

   1.0.0 is the final release published through 'manifest.json'.  The
   gateway operator MAY remove the manifest from the source URL once
   all known devices have been observed connecting to the gateway.

   New devices joining the fleet after retirement MUST be installed
   directly via 'installer.lua', which writes the agent and
   '/startup.lua' without consulting any manifest.


9.  References

   [RFC2119]  Bradner, S., "Key words for use in RFCs to Indicate
              Requirement Levels", BCP 14, RFC 2119, March 1997.

   [RFC-0001] UnisonOS Working Group, "UnisonOS Agent-Era System
              Architecture".

   [RFC-0002] UnisonOS Working Group, "UnisonOS Wire Protocol
              (Gateway-Agent)".
