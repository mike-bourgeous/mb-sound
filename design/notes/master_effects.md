# Master effects

Detailed notes moved from CLAUDE.md (2026-10-10); CLAUDE.md keeps a summary and points here.  Update both when behavior changes.


`Session#master` (`lib/mb/sound/session/master.rb`, console `master { |mix| mix.softclip }`) runs the whole mix through a chain built on `GraphNode::MixSource` channels (one param = the mix as a stereo bundle, N params = one per channel; `master nil` bypasses).  New chains start at `bg`-style launch points (`on:`/`in:`/`at:`) (through the change queue, so chains queued for different times each start; for the same time the latest wins; undo rebuilds the previous chain from its block); by default the old chain "spills over" (fed silence from the switch sample so tails ring out, dropped after 1 s below -90 dB or 10 s), `fade:` crossfades, `fade: 0` cuts (also used when the render load is over 60%).  Clips in a chain follow the timeline like players' clips (non-looping and launch-aligned ones count from the chain's start, `Chain#launch`, through seeks and resumes).  Chains keep processing while idle, `panic` rebuilds the chain to clear tails, and `render` adds the tail after the last player (10 s cap).  Nodes that change the sample count (`resample`, `oversample`) can't be used in a master chain yet.  See Reverbs for which reverbs are light enough for a live master chain.

Shared nodes (fixes-12, 2026-10-14): a chain's nodes may share nodes with players (`lfo = 3.hz.lfo; bg :a, lfo * 0.5; master { |mix| mix * (lfo * 0.5 + 1) }`).  Master chains count as Session graphs for the shared-node bookkeeping in `arrangement.md` (`Strip#span_graphs` lists each non-bypass chain's `Chain#chain_graph`, a `ChainGraph` whose `#graph` covers all its nodes): a muted or kept player sharing a node only with a chain still reads its branch, and a chain waiting to start (a queued `:master` change, an undo's master `:restore`, a chain landing in this span) skips its branches of shared nodes to their Tees' leaders at the start of every span (`Strip#catch_up_waiting`), like a waiting player.  A chain reads its first span from the span's first frame (its input is silent before its start, or its gain 0), so it needs no catch-up inside the span; with `mix * lfo`-style chains the result is exact at any buffer size (`master_spec` 'nodes shared with players': 0.3 s and 1.5 s waits, a replacement while the old chain spills over, a muted player, an undo, at 128/801/7, 800, and 7-frame buffers).  Before, the waiting chain played the node late by its wait (0.3 s: 0.1 off) and its first read after more than a second raised `BranchBufferOverflow` (measured on master-ai 94c421d7); so did unmuting a player that shared a node only with a chain.  Bus chains take part since fixes-13 (`buses.md`, "Shared nodes").

Master gain placement (fixes-6, 2026-10-13; maintainer's option 1): `Session#master_gain` applies before the master chain by default (pre), so a limiter or clipper there keeps its ceiling whatever the gain (before, the gain came after the chain: Loop Church reached +0.76 dBTP with a gain above 0 dB).  `master_gain 2.db, post: true` (`Session#master_gain_post = true`, `Session.new(master_gain_post:)`) puts it back after the chain, like the Pre/Post Fader Insert FX switch in Vegas/ACID; the placement stays until changed (`master_gain post: false`).  Without a master chain both placements give the same samples (spec).  Renders take the current session's placement; set documents save `master_gain x, post: true`; takes save `master_gain_post:` (takes saved before it existed replay post, as they were recorded).  Chain tails count as quiet by the chain's output, so a pre gain changes how long a tail runs by the gain's dB.  Stems are unchanged (each part times the gain).  Always-on master limiting/softclip is for the effects project.

Buses (buses-1, 2026-10-13; `buses.md`) reuse the chain machinery here (`Chain`, `build_master(label:)`, `activate_master`, `render_master_chain`, `master_chain_done?(c, list)`) for named buses with their own inputs; master chains can read buses and players (`mix.duck(:kick)`), bound by `build_master`.

## Mastering presets (mastering-1, 2026-10-17)

Maintainer (2026-10-17, question picker): "Could we get some mastering work done here"; loudness targets reached **both ways** (renders measure, then set the gain exactly, in two deterministic passes; live gets an opt-in slow rider into the limiter); ship all four presets `:club`, `:streaming`, `:quiet`, `:vinyl`.  Standing taste: dance masters low crest and near the maximum true peak, shares at -0.5 dBTP; "less clipping, more limiting" (2026-10-13).  Persona panel round 2 asked for this (#13, #19, H5, `master :quiet`).

**API** (`lib/mb/sound/mastering.rb`, `mastering/targeting.rb`, `mastering/codec_peaks.rb`, `graph_node/rider.rb`, `graph_node/mastering_methods.rb`):
- `master :club` (console and `Session#master(preset, **options, &block)`): a preset ends the master chain; with a block, the block's effects come first (`master(:club) { |mix| mix.filter(:highpass, cutoff: knob(:air)) }`).  Same launch points, spill-over, fades, undo (the chain, its `MasterState`, and `reset_master` carry the preset), journal entries (`master :club, lufs: -9 lands 5:1`).
- `mix.master(:club, ...)` (alias `mastering`) applies a preset anywhere in a graph (recorded by recipes: `.master(:streaming, platform: :apple)`); `mix.ride(-14, ...)` the rider alone.
- Options (`Mastering::OPTIONS`): `lufs:` (LUFS, a `Loudness::TARGETS` name, or a Target), `platform:` (the same, by name), `ceiling:` (true peak, `-1.db`), `drive:` (a fixed trim: renders keep it), `ride:` (true or rider settings), `mono:` (Hz or false), `glue:`, `clip:` (club), `de_ess:` (vinyl crossover Hz or false).  Unknown names raise with did_you_mean.
- `Mastering::Preset` is a frozen Data value: `steps` ([method, args, kwargs], one `[:trim]` gain stage), `target` (Loudness::Target), `ceiling`, `limiter`, `drive`, `fixed`, `ride`, `options`, `notes`, `source`; `#call_ruby` (`:club, lufs: -9`), `#to_ruby`, `#summary`.  `masters` lists them; `masters(:vinyl).notes`.
- Set documents save `master :club, lufs: -9` (and `master(:quiet) { |mix| ... }`), and load both.  Takes replay the typed line.  Genre templates may name a preset as a master step (`master :club, lufs: -8`; the template's `mono_below` becomes the preset's `mono:`).  Song scripts: `--master PRESET|none` (`Session#mastering_override`: replaces presets the song's `master` calls give, is added after plain master blocks; `none` drops presets) and `--lufs N|name`; `genre_demo.rb -M club` swaps a template's chain for a preset.

**The trim.**  Every chain has one gain stage after the level-independent stages (mono low end, subsonic highpass) and before everything that reacts to level, so glue, clipper, and limiter see about the same level whatever the mix: thresholds are written relative to the target (`glue_step(target, over:)`).  Its value is:
- in renders, measured (below);
- live, the preset's `drive`: target minus `ASSUMED_INPUT_LUFS` (-20 LUFS, about where full-scale parts land at the default -10 dB master gain); or
- with `ride: true`, a `GraphNode::Rider` starting there.

**Render targeting** (`Mastering::Targeting`): `render` runs its block twice when a targeted preset ran.  Pass 1 renders normally while a `Capture` records the Session's mix (a tap) and, for each chain with a targeted preset, its input, its output times its fade ramp, and the root random generator's state when it was built.  `Targeting.solve` rebuilds those chains on the closed pass-1 Session (same block, same seeds, `Session#mastering_trim` set) and computes the render's output for any trim as the recorded mix minus the chains' recorded outputs plus their outputs at that trim (so other chains, spill-overs, fades, and post gains are exact).  Secant steps on the BS.1770 integrated loudness from the window's first frame (`from:` renders) reach the target within 0.01 LU in 2-4 chain runs; presets without a limiter (`:vinyl`) then lower the trim until the true peak is under the ceiling ("held").  Pass 2 re-renders with the trim (the root generator put back first).  Everything is sample-exact, so the trim and the file are bit-identical at any buffer size (spec: 128 vs 800).  The block must build its graphs: a graph pass 1 already played raises (`Capture#saw`).  `render(loudness:)` overrides the preset's target (without a preset it still normalizes the file, gain only); `loudness: false` renders once at the drive; `render(master: :club)` masters any render block.  Stems are pre-master, so the trim leaves them alone.  The printed report (`Targeting::Result`, `Targeting.last`; inside `MixReport` with `report:`): pass/fail, integrated vs target, short-term max, LRA, PLR, true peak vs ceiling, side below the mono frequency (or 120 Hz) re mid, decoded MP3/AAC true peaks (streaming presets and reports) with ceiling advice over -0.1 dBTP.

**Rider** (`GraphNode::Rider`, a Channels bundle like LoudnessMeter): K-weighted mean square per sample; 10 ms segments filled sample by sample (sums independent of buffer boundaries); every 100 ms of its own time it reads the short-term loudness (last 3 s, silence before the start), moves the gain (dB) a one-pole step toward target minus loudness (time constants `down:` 3 s when the program gets louder, `up:` 10 s when quieter), within `range:` (9 dB) of the start, and ramps there linearly over the next 100 ms (gain a function of the absolute sample index).  It holds below -70 LUFS and while the input is more than `gate:` (10 LU) under the recent loudest short-term loudness (a peak falling 0.5 LU/s), so silence, fades, and breakdowns don't pump up.  It measures its input (feed-forward), so after heavy limiting the output lands a little under the target.  Same samples at 1/7/128/4801-sample buffers as at 800 (spec).  `master` shows its gain: `master: :club, ride: true (ride +2.4 dB)`.

**Codec true peaks** (`Mastering.codec_peaks(file | channels, codecs:)`): ffmpeg encodes (MP3 320k, AAC 256k, Opus 160k, Vorbis q9), decodes, and measures BS.1770 Annex 2 true peak.

**The chains** (`Mastering.preset(...).steps`; thresholds relative to the target because the trim brings the mix there first):

| preset | chain | target, ceiling |
|---|---|---|
| `:club` | `mono_below(120)` -> trim -> glue `compress(threshold: target + 3 dB, ratio: 2, knee: 6, attack: 10 ms, release: 150 ms, detector: :rms)` -> `softclip(0.9, 1.4)` (`clip: false`: `limit(ceiling: ceiling + 2 dB, lookahead: 1 ms, release: 20 ms)`) -> `limit(ceiling: -0.5.db, release: 80 ms)` | -8.5 LUFS, -0.5 dBTP |
| `:streaming` | trim -> glue (target + 5 dB, 1.5:1, 20/250 ms, RMS) -> `limit(ceiling: platform's, release: 150 ms)` | `platform:`/`lufs:` (default `:spotify` -14 LUFS, -1 dBTP; `:apple_music` -16, `:amazon_music` -2 dBTP, ...) |
| `:quiet` | trim -> `limit(ceiling: -1.db, release: 250 ms)` (`glue: true` adds 1.3:1 at target + 6 dB) | -18 LUFS, -1 dBTP; `lufs: :ebu_r128` -23, `:atsc_a85` -24 / -2 dBTP |
| `:vinyl` | `mono_below(150)` -> 25 Hz highpass -> trim -> glue (target + 5 dB, 1.5:1, 30/300 ms, RMS) -> de-esser `bands(5500) { |lo, hi| [lo, hi.compress(threshold: target - 8 dB, ratio: 4, attack: 1 ms, release: 60 ms)] }`; no limiter | -14 LUFS, true peak held under -1 dBTP by the trim |

Reasons: club and vinyl mono the lows (club systems and cutting lathes; genres.md's decision, 2026-10-13: never for headphone or ambient masters, so streaming and quiet don't); glue is gentle and RMS-detected so it evens sections rather than catching transients; the club's peak stage was chosen by measurement (below) for "less clipping, more limiting"; quiet keeps dynamics (EBU R 128 programmes have LRA 5-20 LU); vinyl has no brickwall because the cutting engineer sets the cut level, and tames sibilance because the RIAA pre-emphasis (about +20 dB at 20 kHz re 1 kHz) makes treble cost groove excursion (sources in each preset's `source`; the RIAA and cutting advice from memory, unverified).

**Tuning measurements** (offline lab, `/tmp/claude-0/mastering-1/lab/lab.rb` (not kept; regenerate by summing a song's `--stems` render at `--stem-gain -12` and running a preset's steps in 800-sample blocks): each song's pre-master mix, the trim found by the same secant search; limiter gain reduction mean / 95th percentile from a 1e-4 probe channel through the linked limiter; clip share = samples over the softclip's threshold):

| song | variant | trim dB | LUFS | ST max | LRA | dBTP | clip % | limiter GR dB (first / final) | MP3 dBTP |
|---|---|---|---|---|---|---|---|---|---|
| Tunnel Vision | own master (dnb_master, drive 11) | | -7.6 | -6.0 | 4.5 | -0.5 | | | |
| | club, softclip(0.8, 1.0) (first cut) | 8.6 | -8.5 | -6.6 | 5.6 | -0.5 | 7.9 | 0.7 / 2.8 | |
| | club (softclip 0.9, 1.4) | 10.6 | -8.5 | -6.9 | 4.5 | -0.5 | 8.1 | 1.6 / 4.5 | +0.37 |
| | club, two limiters (`clip: false`) | 14.3 | -8.5 | -5.6 | 2.2 | -0.5 | | 2.0 / 7.0, 1.3 / 2.0 | +0.64 |
| | single limiter only | 29.7 | -8.6 | -5.4 | 2.9 | -0.5 | | 10.7 / 19.2 | |
| dnb short form | club | 12.1 | -8.5 | -6.6 | 3.6 | -0.5 | 6.7 | 1.5 / 4.3 | +0.31 |
| | club, two limiters | 14.0 | -8.5 | -5.8 | 3.3 | -0.5 | | 1.3 / 5.6, 1.1 / 2.0 | +0.79 |
| house short form | club | 8.8 | -8.5 | -7.5 | 5.8 | -0.5 | 3.3 | 0.5 / 2.0 | -0.26 |
| | club, two limiters | 9.7 | -8.5 | -7.5 | 5.3 | -0.5 | | 0.2 / 1.8, 0.6 / 1.8 | -0.33 |
| techno short form | club | 11.1 | -8.5 | -7.9 | 3.9 | -0.5 | 13.6 | 1.0 / 2.5 | -0.36 |
| | club, two limiters | 14.2 | -8.5 | -7.8 | 3.8 | -0.5 | | 1.0 / 5.1, 0.9 / 2.0 | -0.34 |
| Night Bus (flow) | streaming (Spotify) | 12.7 | -14.0 | -10.3 | 4.4 | -1.0 | | 1.0 / 4.0 | -0.66 |
| | streaming, `glue: false` | 12.2 | -14.0 | -10.6 | 4.2 | -1.0 | | 1.0 / 4.3 | -0.77 |
| Tin Roof | quiet (-18) | -0.4 | -18.0 | -11.5 | 12.4 | -1.0 | | 0.0 / 0.0 | -1.02 |
| Memory Card | vinyl at -3 dBTP (first cut) | -6.9 | -19.2 (held) | -15.1 | 8.4 | -3.0 | | | -2.97 |
| | vinyl at -1 dBTP | -4.7 | -17.1 (held) | -13.0 | 8.3 | -1.0 | | | |
| | -1 dBTP + peak compressor (6:1, 0.5 ms, 1 ms lookahead) | -4.4 | -16.9 (held) | -12.9 | 8.1 | -0.9 | | | |

Tunnel Vision's drums peak about 15 dB over the rest of the mix before any master stage (the song's own chain clips them hard), so a limiter alone pumps and flattens it (LRA 2.9 at 10.7 dB mean gain reduction); the gentle clipper keeps the song's own LRA with 1.6 dB of limiting.  At -0.5 dBTP the decoded MP3s of peaky club masters pass 0 dBTP (Tunnel Vision +0.37, dnb +0.31); the Bench files' 192k MP3s show the same, and the report advises the ceiling.

**CPU** (Mac container (Intel i9-9880H, Docker VM), no YJIT, best of 3 x 20 s of a stereo noise source with a moving level, the source's own cost subtracted; two runs alternating with the same chains written out by hand on a master-ai 8e2df6a1 worktree, which cost the same within noise):

| chain | 128-sample buffers | 800-sample buffers |
|---|---|---|
| club | 86 us, 3.2% of realtime | 275 us, 1.7% |
| club with `ride: true` | 138 us, 5.2% | 388-421 us, 2.3-2.5% |
| streaming | 50 us, 1.9% | 206 us, 1.2% |
| quiet | 34 us, 1.3% | 148 us, 0.9% |
| vinyl | 105 us, 3.9% | 245-257 us, 1.5% |
| rider alone | 54-57 us, 2.0-2.1% | 110-118 us, 0.7% |
| (master-ai, by hand) club / streaming / quiet | 87-89 / 51-52 / 34 us | 287-291 / 203-211 / 143-158 us |

The rider is Ruby around the C biquads (K-weighting) and Numo, so it costs most at small buffers; a C kernel would make it a few percent of that if it matters live.

**Later**: presets with user inserts mid-chain (between the trim and the limiter); a C rider kernel; mapping the club peak stage to a knob (clip vs limit balance); codec-aware ceilings (a render that lowers the ceiling until decoded peaks pass); `render(stems:)` through the preset per stem for stem mastering.
