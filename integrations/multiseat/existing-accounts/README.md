# Existing local Windows desktops

Apply `managed-credential-reveal.patch` to the matching MultiSeat v0.6.7 source,
then run `python prepare_source.py <source-root>` and publish MultiSeat.Service.
This extension adds no package dependencies. Preserve the installed runtime,
configuration, account store, controller gate, and pairing state when updating.

The host agent exposes enabled local SAM accounts with supported MultiSeat names
(ASCII letters, numbers, dot, underscore, hyphen; maximum 20 characters). Microsoft,
domain, built-in and already MultiSeat-managed/linked accounts are excluded.
Admin assignments live in an ACL-protected host file and are mirrored in the
dashboard database. Both sides check the assigned SID before setup.

Every portal Open, Resume, or game launch requires the existing account's Windows
password, including reuse of a ready seat. The service verifies it with LogonUser.
Temporary credentials use a separate memory dictionary, cannot be revealed, and
never enter the MultiSeat account store or portal launch job payload. Windows RDP
credentials use session persistence and are deleted in the existing finally path.
This does not provide secure erasure of immutable strings, paging, or crash dumps.

Setup adds Remote Desktop Users membership where needed; it preserves existing
administrator membership and never enables managed-account privilege elevation.
Existing non-EpicVM Windows sessions must be signed out first. Assignment changes
are refused while the old or new account has a seat, and while setup is running.
Assignments never delete local accounts or their profiles. Removing desktop access
ends the desktop, as the existing access-removal workflow already does.

Password success produces a route-bound, single-use portal handoff unlock lasting
two minutes. Only its digest is saved. Normal and LAN handoffs share authorization;
the LAN page can fall back through a separately signed normal grant. Assignment
generations invalidate prior stream authorization, including after unassignment.
Existing active stream cookies retain the normal session lifetime; refreshing an
already authorized stream tab does not reauthenticate Windows. Returning to the
portal and opening/resuming requires the password again.

Automatic recreation after service restart requires another portal setup and
password entry. Existing-account passwords are intentionally unavailable for
unattended autostart. MultiSeat service updates tear down seats: save and end
active desktops before replacing service binaries.
