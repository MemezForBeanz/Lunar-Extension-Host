# TV/show source research

Observed 2026-11-07 (public, read-only HTTP requests). The index pages were used
to identify candidates; only the provider's own public pages/API responses were
used as capability evidence.

## Added default

### Internet Archive: Classic TV

- **Source URLs/status:** [collection search](https://archive.org/advancedsearch.php?q=collection%3Aclassic_tv%20AND%20mediatype%3Amovies%20AND%20licenseurl%3A%22http%3A%2F%2Fcreativecommons.org%2Flicenses%2Fpublicdomain%2F%22&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=year&fl%5B%5D=date&fl%5B%5D=description&rows=10&output=json) returned HTTP 200 and `response.numFound=1232`; [collection metadata](https://archive.org/metadata/television) returned HTTP 200 on GET and describes Television as recordings including old television shows. The provider constrains results to `collection:classic_tv`, `mediatype:movies`, and the item `licenseurl` public-domain label, not movie-only sources.
- **Native metadata/art:** the representative [The Trouble with Father item](https://archive.org/details/The_Trouble_With_Father) returned HTTP 200 and supplied the title, a 1950s TV description, publisher, runtime, subjects, collection membership, a public-domain usage label, and an item tile at `https://archive.org/services/img/The_Trouble_With_Father`.
- **Episode/show evidence:** the representative item is explicitly an episode (“Many Happy Returns”) of a 1950–1955 sitcom. A second item, [This Is Your Life - Dick Clark 1959](https://archive.org/metadata/ThisIsYourLife-DickClark1959), is in `classic_tv` and identifies the NBC documentary series and a 497.83-second MP4. The collection is an item catalog rather than a normalized season/episode database; episode numbers are not guaranteed and may be encoded only in title/description.
- **Stream resolution:** each metadata response exposes actual files, not just an embed. `The_Trouble_With_Father` exposes an original MP4 plus IA H.264 MP4 and OGV derivatives; the adapter selects the best MP4/WebM/OGV and resolves it to `https://archive.org/download/<identifier>/<file>`. This is a direct media URL, unlike a webpage or iframe.
- **Download:** discovery keeps `https://archive.org/details/<identifier>` as canonical provenance and lazily fetches bounded item metadata before transfer. The selected `https://archive.org/download/<identifier>/<file>` is persisted separately as the transfer URL, then copied by the bounded download path into a user-selected library. No account, API key, CAPTCHA, DRM, or player bypass was used.
- **Limits/rights:** the collection is user-uploaded and mixed: metadata can be inaccurate (the item review notes the episode title may be wrong), some items have no playable derivative, files are large, and collection membership does not itself prove a license. The representative item declares public domain, but users must check the item's usage/rights label before downloading. Archive availability and item servers can change; there is no geography guarantee.

## Candidates investigated but not added

### FMHY video index and THE-OMEGATHREAD

- **Index evidence:** [FMHY video](https://fmhy.net/video) returned HTTP 200 and lists many TV-capable aggregators as “Movies / TV / Anime”, often with auto-next and 4K. [THE-OMEGATHREAD](https://github.com/dwongdev/THE-OMEGATHREAD) returned HTTP 200 and describes itself as a piracy aggregator index, linking FMHY and other streaming/download resources.
- **Why no default was added:** these are indexes, not media providers. The listed sites commonly rely on custom players and third-party/embedded servers, so a public page check does not verify a stable, site-native catalog API, direct stream URL, or authorized download capability. Domains, content rights, geography, authentication, and anti-bot behavior also change frequently. Adding one would require a site-specific adapter and test fixtures, and would risk presenting unresolved embeds as playable media. No episode was downloaded or DRM/CAPTCHA/paywall bypass attempted.

### Other public TV sources

PeerTube series channels and official episodic feeds can be technically viable (native metadata, ordered episodes, and direct enclosures/stream URLs), but no single stable, rights-clear, TV-only catalog with enough coverage was verified in this pass. The existing generic `feed` provider remains available for an official feed URL supplied by the user; it is intentionally not promoted as a universal TV catalog.

## Contract mapping

The result follows [the Mihon-oriented source contract](source-contract.md):
browse/search returns bounded cards with source IDs; Archive details retain the
item URL, title, description, poster, and attribution; resolution requires an
actual media file; and download is separate from catalog discovery. Stream
quality is constrained by the files Archive exposes (the examples are 320x240
MP4/OGV), not a claimed 4K capability.
