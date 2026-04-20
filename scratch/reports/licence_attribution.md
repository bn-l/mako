# Phase 0 — licence + attribution

## kokorog2p itself

`scratch/kokorog2p/LICENSE` is a verbatim Apache License Version 2.0.

From `README.md` § Credits:

> kokorog2p consolidates functionality from:
> - [misaki](https://github.com/hexgrad/misaki) — G2P engine for Kokoro TTS
> - [phonemizer](https://github.com/bootphon/phonemizer)
> - German: 738k+ entries from Olaph/IPA-Dict
> - French: Gold-tier dictionary
> …

`kokorog2p/en/lexicon.py` header:

> """Lexicon-based G2P lookup for English.
> Based on misaki by hexgrad, adapted for kokorog2p."""

The English dicts we care about (`us_gold.json`, `us_silver.json`) are
derived from Misaki. **Misaki is Apache-2.0-licensed (verified 2026-04-19)** (verify at
<https://github.com/hexgrad/misaki/blob/main/LICENSE> before we ship).

## Compliance actions for the port

1. **Ship `ThirdPartyLicenses/kokorog2p/LICENSE`** (Apache-2.0 copy).
2. **Ship `ThirdPartyLicenses/misaki/LICENSE`** (Apache-2.0 copy) — required
   because we will be redistributing Misaki-derived dict data whether
   we get it through kokorog2p or directly from Misaki.
3. **Add `NOTICE`** at project root with:

       mac-tts includes the following third-party components:

       - kokorog2p (Apache-2.0) — portions of the pipeline and English
         lexicon are adapted from github.com/holgern/kokorog2p. See
         ThirdPartyLicenses/kokorog2p/LICENSE.

       - misaki (Apache-2.0) — the English pronunciation dictionaries
         are derived from github.com/hexgrad/misaki. See
         ThirdPartyLicenses/misaki/LICENSE.

4. Update `README.md` § Credits section to cite both.

## Opinions / caveats

- Apache-2.0 all the way down; no copyleft concerns for inclusion
  in a closed-source distribution.
- If FluidAudio's bundled Misaki data already ships with its own
  NOTICE / LICENSE copy (check `.build/checkouts/FluidAudio/ThirdPartyLicenses/`
  during Phase 1), we may have partial compliance already; still need
  to verify and extend.
- **TODO during Phase 1**: confirm kokorog2p's dicts are byte-identical
  to Misaki's, or diverge. If kokorog2p modified entries, treat as
  kokorog2p-derived (Apache-2.0) with Misaki as upstream. If they're
  byte-identical, the source is arguably still Misaki (MIT) regardless
  of which project we fetch them from.
