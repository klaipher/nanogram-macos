# Link hygiene

Status: written with the Mac "Nanogram features" screen (2026-11-14). The list lives in
`packages/NanogramRuntime/Sources/NanogramRuntime/LinkHygiene.swift` (`trackingPrefixes`, `trackingParameters`,
`hostSpecificParameters`). iOS and Android should copy the same list so all three apps clean the same links. Mercurygram's
`MgUrlCleaner` was the reference for what to cover; the list was written from scratch and is intentionally shorter.

## Rules

- Applies to `http` and `https` links only, when a link is OPENED or COPIED. Outgoing message text is never rewritten.
- Never touches Telegram links (`t.me`, `telegram.me`, `telegram.dog`, `telesco.pe`, `tg:`), because their parameters
  (`start`, `domain`, `post`, ...) are meaningful.
- Removed on every host: names starting with `utm_`, `pk_`, `mtm_`, `hsa_`, and `fbclid`, `gclid`, `gclsrc`, `gbraid`,
  `wbraid`, `dclid`, `gad_source`, `gad_campaignid`, `msclkid`, `yclid`, `twclid`, `ttclid`, `li_fat_id`, `epik`,
  `rdt_cid`, `igshid`, `igsh`, `mc_eid`, `mc_cid`, `_hsenc`, `_hsmi`, `__hssc`, `__hstc`, `__hsfp`, `hsctatracking`,
  `mkt_tok`, `vero_id`, `vero_conv`, `oly_enc_id`, `oly_anon_id`, `rb_clickid`, `s_cid`, `wickedid`, `_openstat`,
  `ref_src`, `ref_url`, `fb_action_ids`, `fb_action_types`, `fb_source`, `fb_ref`, `ml_subscriber`, `ml_subscriber_hash`,
  `irclickid`, `cjevent`.
- Removed only on named hosts (and their subdomains): YouTube and Spotify (`si`, `feature`, `pp`), Twitter and X (`s`, `t`),
  Instagram and Threads, Facebook, TikTok, Amazon (`tag`, `linkCode`, `linkId`, `ascsubtag`, `ref_`, `pd_rd_*`, `pf_rd_*`),
  LinkedIn, Reddit, Medium. See the source for the exact names.
- Names are compared case-insensitively and percent-decoded. The remaining parameters keep their order and exact bytes;
  the fragment is kept; a query that becomes empty loses its `?`.
- Optional, separate: ask for confirmation before opening `t.me` and `tg://` links (not for plain web links, which keep
  upstream's own confirmation rules).

Both switches are off by default (Nanogram Features > Links). Tests: `NanogramRuntimeTests/LinkHygieneTests`.
