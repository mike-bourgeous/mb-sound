# Master effects

Detailed notes moved from CLAUDE.md (2026-10-10); CLAUDE.md keeps a summary and points here.  Update both when behavior changes.


`Session#master` (`lib/mb/sound/session/master.rb`, console `master { |mix| mix.softclip }`) runs the whole mix through a chain built on `GraphNode::MixSource` channels (one param = the mix as a stereo bundle, N params = one per channel; `master nil` bypasses).  New chains start at `bg`-style launch points; by default the old chain "spills over" (fed silence from the switch sample so tails ring out, dropped after 1 s below -90 dB or 10 s), `fade:` crossfades, `fade: 0` cuts (also used when the render load is over 60%).  Clips in a chain follow the timeline like players' clips (non-looping and launch-aligned ones count from the chain's start, `Chain#launch`, through seeks and resumes).  Chains keep processing while idle, `panic` rebuilds the chain to clear tails, and `render` adds the tail after the last player (10 s cap).  Nodes that change the sample count (`resample`, `oversample`) can't be used in a master chain yet.  See Reverbs for which reverbs are light enough for a live master chain.
