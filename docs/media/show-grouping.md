# Show and season grouping

TV scanning builds one show, its numbered seasons (including season zero for
specials), and numbered episodes. Release-pack and episode directory names are
containers, not separate shows. A corroborating series folder supplies the title
and remake year; an episode filename can identify a different series within a
franchise folder. Season suffixes, release labels, and season air years do not
become part of the show title.

An undated season can join a single unambiguous dated series in the same library.
Explicitly conflicting years remain separate. Without enough naming information,
Lunar leaves ambiguous series separate rather than choosing a remake by popularity.

Existing catalogs are repaired during a normal library rescan, including the
automatic scan after restarting media-server. Files retain their IDs, paths,
analysis and tracks. Duplicate episode copies join the same numbered episode;
each user's most recent resume/watched state is retained. Collection membership
and local artwork follow the new hierarchy. Provider facts carry between equally
named series; a mismatched provider identity from a release-folder title is not
treated as authoritative. Empty obsolete grouping rows are removed only after
their files and user state have been transferred. No video files are renamed or
moved. Repeating the scan leaves the resulting hierarchy unchanged.

## Plex reference inspection

Read-only REA/Ghidra inspection of the user-selected Windows installation at
`D:\Program Files\Plex\Plex Media Server`, 2026-11-07. Scanner SHA-256:
`13a4bdd35a5a279ad63cafa318546ef10f1f556839bf109f1c5bedf4705afa29`.

- Native function `0x1401418b0` initializes and applies a filename expression with
  named show, season, episode, second-season and second-episode captures.
  Decompilation evidence: `ev_ad6b8bec29e8f4a7b6aa71da6b9578215a92d794913b64a0d7efc8c65a59b8f1`.
- Native function `0x140292250` checks for an existing season and contains a
  season-creation branch associated with a show and a season number, with source
  diagnostics identifying `Library/Season.cpp`. Its parent/number interpretation
  is inferred from the diagnostic, lookup and metadata construction together.
  Decompilation evidence: `ev_e09e99877a42ea95aa2430b2874021f1ac410779fc3dc98037023c5494cbe1bc`.
- String-reference evidence:
  `ev_f081a96a0f3e7f2dc39cb07d84a03df3af51d9d654da69c37b439602d71b6b1b`,
  `ev_64eb94b9e01af5bb89c440d6b21aff7a15a3bb8acfb70922340d0ea7053c56f8`.

These selected functions do not establish Plex's entire series matching algorithm.
PDB symbols were unavailable; decompiled types and names are inferred. No Plex
implementation code or private libraries were copied into Lunar. A separate
read-only export of the running Plex server's episode assignments was used as a
validation reference, not imported as Lunar identities. The Lunar fix was also
replayed twice against a consistent snapshot of its actual catalog to check file
and progress preservation, foreign keys, integrity and repeatability.

Regression coverage: `spec/media_server_spec.lua` (naming, duplicate copies,
regrouping existing catalogs, user state, optional years and distinct remakes).
