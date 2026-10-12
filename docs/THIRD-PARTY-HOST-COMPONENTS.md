# Host component distribution notes

The preview package contains third-party runtimes and hosting components. Preserve their original notices and licenses. This document records the checked sources; it does not replace the complete corresponding-source and notice review required before public distribution.

| Component | Pinned source | Checked license or release requirement |
| --- | --- | --- |
| MultiSeat 0.6.7 | https://github.com/vibesoftwarecoder/MultiSeat/tree/v0.6.7 | MIT. Retain its copyright and license notice. |
| ApolloVibe 2026.6.1-ms6 | https://github.com/vibesoftwarecoder/ApolloVibe/tree/v2026.6.1-ms6 | GPL, as published in the tagged LICENSE. Include the applicable license and satisfy corresponding-source obligations, including changes. |
| Apollo 0.4.6 SudoVDA payload | https://github.com/ClassicOldSong/Apollo/tree/v0.4.6 | Apollo publishes a GPL license. Separately check the driver payload's own notices and redistribution terms; do not infer them solely from the repository license. |
| Moonlight Web viewer | https://github.com/mrcreativ3001/moonlight-web-stream | Identify the exact source revision and corresponding runtime/frontend license notices for the digest-pinned Linux image and Windows viewer before public distribution. |
| ViGEmBus and HidHide | https://github.com/nefarius/ViGEmBus and https://github.com/nefarius/HidHide | Preserve signed vendor installers and their notices. Check their pinned release terms. |
| Python, .NET, PowerShell, Caddy and NSSM | Their bundled upstream runtime distributions | Preserve original license/notice files and verify the selected versions. Do not replace vendor signatures with EpicVM's own signature. |

The component installer verifies pinned archive digests and applicable installer signatures. That integrity check does not by itself satisfy license obligations. Release signing is restricted to EpicVM's Agent/Control launchers and setup scripts; third-party binaries retain their vendor identity.

The builder should produce a corresponding-source archive and notices alongside a public release. No public signed release or license-complete distribution is asserted by this preview.
