# EpicVM UX review, October 10, 2026

The goal is an invited friend signing in, finding their hosted Windows desktop,
opening it, and understanding how to return or finish. The visual style is
consistent and the sign-in form is straightforward. The main problem is that
the product still guides users toward VMs and connecting their own PC.

Public landing/sign-in were captured live. Signed-in screens were captured from
the current built frontend with an isolated, approved-account fixture containing
two assigned desktops and no VMs. This is a representative UI state, not a
production account. Launch delay was simulated locally; no production account,
desktop, or configuration was changed.

## Steps and findings

1. **Public landing: clear buttons, misleading expectations for multiseat.**
   The visible illustration is a Linux VM. The page says most approved users
   receive Linux VMs, describes automatic VM creation, and directs users to the
   VM Portal. An invited desktop user could expect a different product. Make
   hosted desktops and games the leading explanation for this release.

   ![Live landing](01-live-landing.png)

2. **Sign-in: mostly healthy.** Username/password fields have visible labels,
   and the primary action is clear. Replace “VM Portal” with wording that
   includes hosted desktops. Authentication and password-error behavior were
   not exercised with a real production account.

   ![Live sign-in](02-live-signin.png)

3. **Portal entry: high-priority discoverability problem.** Assigned desktops
   are collapsed under “Games and desktops.” The same view says “2 ready to
   open” and “No machines yet ... Check back shortly.” The latter condition
   only checks the VM list in Portal.jsx, independently of desktop grants.
   A large “Connect your PC” card offers an unrelated task. Show assigned
   desktops immediately, suppress the VM empty state when other resources are
   available, and move connecting one's own PC into a secondary location.
   The fixture supplied an empty VM summary; its blank statistic values are
   not evidence of a production statistics defect.

   ![Collapsed portal preview](03-preview-portal-collapsed.png)

4. **Expanded desktop cards: understandable opening action, unclear ending.**
   “Open desktop” and “Resume desktop” are good labels. “End session” does not
   explain whether it merely closes streaming or closes running Windows apps.
   Source inspection shows it directly invokes seat deletion without a
   confirmation. Explain the consequence and distinguish disconnecting from
   ending the Windows session. No end-session action was executed in this audit.

   ![Expanded portal preview](04-preview-portal-expanded.png)

5. **Mobile portal: reflows, but the helper overlaps content.** At 390 pixels
   wide the document had no horizontal overflow. Cards stack correctly. Epi's
   fixed helper occupies much of the lower screen and overlaps desktop-card
   content. Use a compact mobile launcher or a dismissible prompt. Full keyboard,
   screen-reader, contrast, zoom, and live-stream touch checks remain untested.

   ![Mobile portal preview](05-preview-mobile-portal.png)

6. **Launching/resuming: insufficient progress and recovery feedback.**
   Clicking one desktop sets every desktop button to “Preparing...” while badges
   remain “Ready.” The shared busy state does not identify the selected desktop.
   SharedGames.jsx uses fetch without a launch timeout, and the observed waiting
   screen has no progress explanation, cancellation, or retry guidance. Track
   the selected card, announce progress through a status region, and provide
   recovery when preparation stalls. The waiting state was simulated, so this
   does not measure actual provisioning time.

   ![Preparing preview](06-preview-preparing.png)

## Limits and recommended order

The signup form was inspected live through the DOM, but its screenshot timed
out; it is not included as a screenshot-backed audit step. Its copy also promises
machine provisioning after approval. No account was submitted.

Actual public pairing, the running stream toolbar, reconnect after a network
failure, and the Windows desktop were not exercised. Their UX still needs a
separate end-to-end pass. Browser fixture state is insufficient to certify them.

Fix portal discoverability and the contradictory empty state first, then the
End session explanation, launch feedback, multiseat entry-page wording, and
mobile helper. Jev independently prioritized the portal discoverability issue
from the observed text; the recommendation is grounded in the screenshots and
source conditions above.

## Fixes deployed 2026-10-10

All six findings above were addressed in the frontend:

- Desktops are expanded on first load and placed before games.
- The portal suppresses VM-only empty messaging when desktops/games are assigned, loading, or availability checks fail. True unassigned accounts receive an assignment explanation.
- End session opens a native modal, focuses Keep session, explains closing apps/sign-out/unsaved work, and requires explicit confirmation. Closing the stream tab and resuming is explained next to active desktops.
- Only the selected resource shows connecting/ending feedback. Requests have a two-minute timeout, Stop waiting, status refresh, and explicit launch retry. Stop waiting explains that the host request continues. No automatic POST retries.
- Landing, sign-in, signup, approval, helper, and metadata copy prioritize hosted Windows desktops and games. Own-PC streaming remains a secondary collapsed option.
- The mobile helper is a 52px circle with scroll space reserved below portal content.

Validation: production Vite build passed. Browser wrapper checks against a local authenticated fixture passed expanded desktop discovery, modal state and default focus, Keep session and Escape handler cancellation, exactly one stop POST for the selected host, selected launch feedback, abort recovery, HTTP 503 explanation/retry, honest unassigned and unavailable states, opening Alpha and Beta with correct host IDs, and approved-account copy. Mobile 390x844 showed no horizontal overflow; compact helper opens and closes. Jev judged the session distinction clear and the desktop the primary task from observed portal text; deterministic browser assertions and screenshots were used independently.

Live verification: landing, sign-in, signup, JS, and CSS returned HTTP 200. Browser observed the new desktop-first landing, sign-in and signup text; signup mobile had no horizontal overflow. Dashboard container remained running and healthy. Live index references index-BwBdWr7b.js and index-BjYUv-63.css. After screenshots: after-portal.png, after-mobile.png, live-after-landing.png. Sign-in after screenshot timed out; its live DOM was verified.

Deployment: static frontend and scoped frontend source files deployed to /opt/blobe-vm. Hashed assets were copied first and index.html replaced atomically last. Old assets retained. Backup: /opt/blobe-vm/backups/ux-20261010T170600Z. Rollback: restore backup/dist/index.html atomically to /opt/blobe-vm/epicvm_web/dist/index.html, with backup assets already available; scoped source originals are under the same backup directory. No container restart, account changes, backend changes, or controller changes.

Limits: authenticated interactions used fixture responses, not production Windows sessions. No hands-on/controller test was requested. Actual stream toolbar, network reconnect, public pairing, and Windows interaction remain outside this UX pass. Native Escape handler was checked via a dispatched keyboard event; no full assistive-technology audit was performed.
