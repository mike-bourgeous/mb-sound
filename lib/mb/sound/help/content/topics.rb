# Help topics for the bin/sound.rb console (`help :knobs`, `help.topics`).
#
# Written in `module MB::Sound` (not Help) so notes like A1 in examples
# resolve through MB::Sound.const_missing, as they do in the console.  Only
# the names, a blurb, and the examples are hand-written: each name's line
# comes from its doc comment.  The guard spec (spec/lib/mb/sound/help_spec.rb)
# checks every name, plays every example, and checks its level: peaks at
# most Help::Level::EXAMPLE_PEAK_OVER_TONE_DB over the tone, loudness within
# Help::Level::EXAMPLE_LOUDNESS_WINDOW of the level check tone (a triangle
# peaking at -30 dBFS, about -35 LUFS).  Tones at about -20 dB before the
# master bus land there; the monitor trim (help.level) brings them to the
# listening level.
# Player names start with `try` so an example never replaces your players.
module MB
  module Sound
    Help.topic :play, 'Playing things', group: :start do
      about <<~TEXT
        Everything plays through one background Session that mixes every
        player on a shared timeline; `play` is the foreground version
        (waits until the sound ends; Ctrl-C to stop).  Commands return
        journal entries that say where they land.  Sounds end through
        envelopes, clips, `until`, or `stop`.  `play`, `bg`, and `render`
        take graphs and more: files, audio arrays, Samples (once), Slices
        (one by one), clips (on their instrument, e.g. a chop's slices, or
        a soft saw), grids (a TR-808), instruments and SF2/SFZ files (a
        demo phrase), wavetables (one note), and presets by name.
      TEXT
      commands :bg, :stop, :outro, :panic, :players, :stopped, :resume, :forget, :play, :wait, :master_gain, :monitor_gain, :warm_up
      dsl :at, :until, :and_then
      note :method_modules
      see :sets, :now, :files
      example 'a quiet triangle that stops itself' do
        bg :try, 220.hz.triangle.at(-20.db).until(2.bars)
      end
      example 'a pattern on the next bar' do
        bass = seq(A1, A1, rest, A2, A1, rest, G1, E1).n8.loop
        bg :try, bass.tone.ramp.at(-12.db).lp4(600, resonance: 0.4) * bass.amp_env
      end
      example 'play a clip on the default patch' do
        play seq(A3, C4, E4, A4, E4, C4, A3.n4).n8, gain: -14.db
      end
      example 'play two seconds of a drum file as a Sample', bars: 1 do
        play Sample['sounds/drums.flac'].trim(...2.seconds), gain: -8.db
      end
      example 'play a grid on a TR-808' do
        play grid(16, kick: 'X...x...', snare: '....x...', hat: 'x.x.x.x.'), gain: -12.db
      end
    end

    Help.topic :files, 'Files, inputs, and outputs', group: :start do
      about <<~TEXT
        Read and write sound files (anything ffmpeg knows), play files and
        live input through graphs, and choose the output and its latency.
      TEXT
      commands :read, :write, :list, :file_input, :file_output, :input, :output, :use_output, :latency, :loopback, :close_outputs
      note :audio_io
      see :record
      example 'two bars of a drum file' do
        bg :try, file_input('sounds/drums.flac').at(-8.db).until(2.bars)
      end
    end

    Help.topic :tones, 'Oscillators and pitches', group: :sound do
      about <<~TEXT
        `440.hz` is a Pitch; oscillator methods make a Tone (antialiased by
        default, `a*` twins are naive).  Phases are in cycles.  Lengths
        (`250.ms`, `1.n8`) and intervals (`7.semitones`) work everywhere.
      TEXT
      commands :silence, :impulse
      dsl :ramp, :square, :triangle, :sine, :pulse, :pwm, :fm, :pm, :fm_feedback, :sync, :unison, :swarm,
        :wavetable, :harmonics, :noise, :lfo, :transpose, :glide
      note :oscillators, :numbers_lengths_phases
      see :envelopes, :filters, :random
      example 'detuned unison saws' do
        bg :try, 110.hz.unison(5, detune: 0.2) { |p| p.saw }.lp4(1200).at(-24.db).until(2.bars)
      end
      example 'FM bell' do
        bg :try, 440.hz.fm(660.hz.at(400) * env([[1, 0], [0, 1.5, 60]])).at(-16.db) * env([[1, 0.005], [0, 2, 40]])
      end
    end

    Help.topic :unison, 'Unison and supersaws', group: :sound do
      about <<~TEXT
        Three spellings, the same sound bit for bit:
        `110.hz.unison(5, spread: 0.5) { |p| p.ramp }` (the block form, any
        oscillator per copy), `110.hz.unison(5, spread: 0.5).ramp` (shape
        methods on a blockless unison; used as a signal it is saws), and
        `110.hz.ramp.unison(5, spread: 0.5)` (a tone made again on every
        copy).  In synth voices: `v.hz.saw.unison(5) * v.amp_env`.
        `detune:`, `spread:` (0..1, stereo above 0), `mix:` (side copies),
        `swarm` for gliding copies.
      TEXT
      dsl :unison, :swarm
      note :oscillators
      see :tones
      example 'three spellings, one supersaw' do
        bg :try, 110.hz.saw.unison(5, detune: 0.2, spread: 0.5).lp4(1200).at(-24.db).until(2.bars)
      end
    end

    Help.topic :envelopes, 'Envelopes and curves', group: :sound do
      about <<~TEXT
        Envelopes land exactly on their targets at whole samples; curves
        are signed dB (+60 falls like a 60 dB exponential).  Without a gate
        they are one-shots.
      TEXT
      commands :adsr, :env, :amp_env, :filter_env, :fm_env, :sq80_env, :tween, :bounce_hits
      dsl :smooth, :ease
      note :envelopes, :curves
      example 'a plucked note' do
        bg :try, 220.hz.saw.at(-12.db).lp4(300 + env([[3000, 0.002], [0, 0.4, 40]])) * env([[1, 0.002], [0, 0.8, 60]])
      end
    end

    Help.topic :filters, 'Filters', group: :sound do
      about <<~TEXT
        Cookbook filters (`filter(:lowpass, cutoff:, quality:)`) build SVFs
        whose parameters can move every sample; `lp4` is a CEM3379-style
        four-pole, `diode` a 303-style ladder with the same knobs.
      TEXT
      dsl :filter, :lp4, :diode, :peq, :formant, :smooth
      note :filters
      see :knobs
      example 'a swept four-pole' do
        bg :try, 55.hz.ramp.at(-16.db).lp4(tween([200.hz, 4000.hz, 200.hz], 2.bars), resonance: 0.6).until(2.bars)
      end
    end

    Help.topic :effects, 'Effects', group: :sound do
      about <<~TEXT
        Sums ring until their last input ends (a gong past its click, a
        dry part plus its reverb); `(drone + hit).ring(:first)` (or
        `render(..., ring: :first)`) ends with the first.
        Delays (sinc-interpolated, tempo-synced lengths), feedback loops that
        run one sample at a time in C, the FDN reverb with presets, the
        Juno chorus, and antialiased shapers.
      TEXT
      dsl :delay, :multitap, :feedback, :reverb, :chorus, :softclip, :clip, :decimate, :quantize, :ease, :oversample, :ring
      note :delays, :feedback_loops, :reverbs, :chorus
      see :dynamics, :mixing
      example 'a dotted-eighth echo' do
        blip = seq(E5, rest, rest, rest, B4, rest, rest, rest).n8.loop
        bg :try, (blip.tone.triangle.at(-14.db) * blip.amp_env).delay(1.n8.dotted, feedback: 0.5)
      end
      example 'a plate' do
        clip = seq(E4, rest, B4, rest).n8.loop
        notes = clip.tone.saw.at(-16.db) * clip.amp_env
        bg :try, stereo(notes, notes).reverb(:plate)
      end
    end

    Help.topic :dynamics, 'Dynamics', group: :sound do
      about <<~TEXT
        One compander core: compress, expand, gates, ducking, compand
        curves, a true-peak limiter, crossover bands, and squeeze.  Levels
        and gains in dB are written `-12.db` (`threshold: -18.db`,
        `makeup: 3.db`, `compand(-60.db => -80.db, 0.db => -12.db)`);
        bare numbers are linear gains.
      TEXT
      dsl :compress, :expand, :noise_gate, :duck, :compand, :limit, :bands, :squeeze, :loudness_meter
      note :dynamics
      see :mixing
      example 'ducking a pad under a kick' do
        kick = tr808(grid(16, kick: 'x...x...x...x...').loop)
        bg :try, 110.hz.saw.at(-16.db).lp4(900).duck(kick.at(-12.db)) + kick.at(-12.db)
      end
    end

    Help.topic :blend, 'Mixing an effect in (wet and dry)', group: :sound do
      about <<~TEXT
        `sig.blend(0.3) { |s| s.resonate(:plate) }` mixes the effect the
        block makes from `sig` with `sig` itself: 0 is all dry, 1 all wet,
        the same law as the effects' own `mix:` (dry * (1 - mix) + wet *
        mix).  The mix can be a number, a knob's name (`blend(:wet)`, turned
        with `turn :wet, 0.8`), or any node (an LFO, an envelope).
        `curve: :power` keeps the loudness of effects that don't correlate
        with the dry sound (reverb tails); effects with lookahead
        (compressors, limiters) get their dry path delayed to match.  A
        stereo bundle goes to the block whole.

        The same by hand: `sig * 0.7 + sig.resonate(:plate) * 0.3` (using
        `sig` twice is fine: the graph branches it).  Some effects mix
        themselves: `reverb(mix: 0.3)`, `chorus(mix:)`, `delay(dry:, wet:)`,
        and the dynamics' `mix:` (parallel compression).  For one effect
        shared by several tracks, send them to a bus (`bus(:verb) { |s|
        s.reverb(:hall, mix: 1) }`, then `track(:keys, send: { verb: -12.db
        })` or `feed :keys, :verb, -6.db`): the bus is all wet, and each
        send sets how much goes in.
      TEXT
      commands :bus, :feed, :knob
      dsl :blend, :resonate, :reverb, :chorus, :delay
      see :effects, :buses, :knobs
      example 'drums into a swept resonator, mixed in' do
        beat = tr808(grid(16, kick: 'x...x...x...x...', snare: '....x.......x...', hat: 'x.x.x.x.x.x.x.x.').loop)
        # (the resonator rings far louder than its strikes)
        bg :try, beat.blend(0.4) { |s| s.resonate(:plate, 0.25.hz.lfo.at(110..440), decay: 1.5).at(-22.db) }.at(-11.db)
      end
    end
    Help::TOPIC_ALIASES.merge!(wet: :blend, dry: :blend, mix: :blend, wetdry: :blend, dry_wet: :blend)

    Help.topic :stereo, 'Stereo and channels', group: :sound do
      about <<~TEXT
        Bundles (`stereo(l, r)`) broadcast DSL calls per channel; per-channel
        arguments come from bundles or `per_channel`.
      TEXT
      commands :stereo, :channels, :per_channel, :spread
      dsl :pan, :balance, :width, :mono, :mid_side, :matrix, :place, :left, :right
      note :multichannel
      example 'two detuned channels, narrowed' do
        bg :try, stereo(220.hz.saw, 220.5.hz.saw).lp4(1500).at(-20.db).width(0.6).until(2.bars)
      end
    end

    Help.topic :drums, 'Drums', group: :sound do
      about <<~TEXT
        Drum machines driven by a grid (Sequence::Kit) or MIDI (GM notes):
        `tr808`, `tr909` (analog kick, snare, toms, clap; 6-bit sampled hats
        and cymbals; `shuffle:` 0..6, flams as note marks: 'f' in a grid or
        `D1.flam`), and kits of your own:
        `kit { voice :kick, tune: 50 do |h| h.body(h.tune, sweep: 3) +
        h.click end; choke :open_hat, by: :closed_hat }` with layers
        (body, noise, click, metal, sample, fm, bursts, env, sweep) and
        voices borrowed from the machines (`tr909 :clap`, `tr808 :cowbell`).
      TEXT
      commands :tr808, :tr909, :kit, :drum_kit, :grid, :euclid
      note :drums
      example 'four on the floor' do
        bg :try, tr808(grid(16, kick: 'x...x...x...x...', hat: 'x.x.x.x.x.x.x.x.').loop).at(-14.db)
      end
      example 'a 909 with shuffle' do
        bg :try, tr909(grid(16, kick: 'X...x...x...x...', clap: '....X.......X...', hat: 'x.xxx.xxx.xxx.xx', oh: '..x...x...x...x.').loop, shuffle: 2).at(-16.db)
      end
      example 'a kit of your own' do
        bg :try, kit(grid(16, kick: 'X..x..x...x..x..', snare: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop) {
          voice(:kick, tune: 45) { |h| h.body(h.tune, decay: 0.4, sweep: 4).softclip(0.6) + h.click(0.3) }
          voice(:snare) { |h| h.fm(240, ratio: 2.3, index: 1, decay: 0.12, index_decay: 0.03) * 0.5 + h.noise(decay: 0.15, highpass: 2000) * 0.4 }
          tr909 :closed_hat
        }.at(-14.db)
      end
    end

    Help.topic :sq80, 'SQ-80 voice and patches', group: :sound do
      about <<~TEXT
        `sq80` is an Ensoniq SQ-80-flavored synth built from the library's
        pieces (original wave tables, nothing from the SQ-80's ROM): OSC1
        a formant wave whose vowel stays put across the keyboard, OSC2 a
        SYNTH 3-style table, OSC3 a PRIME-style table an octave down
        blipped by ENV1, into a driven four-pole (lp4); SQ-80 panel units
        on the envelopes (`sq80_env`: times 0..63, levels -63..+63), a
        delayed vibrato, and two oddities: chop (octaves; a looping
        32nd-note filter envelope) and flutter (octaves; each key's poly
        pressure sets its own sample-and-hold filter flutter).  It takes
        any MIDI source (none: live `midi`), a patch, and settings, as in
        `sq80(clip, :chop)` or `sq80(:glass, cutoff: 900)`.  Patches:
        :classic (the defaults), :flutter_pad, :chop, :vox_lead,
        :prime_bass, :glass (`sq80_patches` lists them).  Settings:
        voices, cutoff (Hz), reso (0..1), drive_mode (:feedback or
        :input), drive, chop, flutter, second_release, osc1..osc3 (wave,
        semitones, level, vibrato, env1), env1, env2, env4 (sq80_env panel
        values), lfo1 (rate in Hz, depth in semitones, delay, wheel,
        pressure), filter (env2, key, velocity, aftertouch, in octaves),
        level; Hash settings change only the keys given
        (`env4: { t4: 50 }`).  Each patch is a preset too
        (`preset :sq80_glass, midi: midi`), and the shell plays them with
        bin/synths/sq80_voice.rb -p glass.
      TEXT
      commands :sq80, :sq80_patches, :sq80_env
      note :sq80, :envelopes
      see :midi, :presets, :envelopes
      example 'the chop patch on a chord' do
        bg :try, sq80(seq(A3, F3).n2 & seq(C4, A3).n2 & seq(E4, C4).n2, :chop).at(-16.db)
      end
      example 'a vowel lead, darker, with a longer release' do
        bg :try, sq80(seq(A4, C5, E5.n4, D5, C5, B4.n4).n8, :vox_lead, cutoff: 900, env4: { t4: 40 }).at(-16.db)
      end
    end

    Help.topic :sampler, 'Sampler: bounce, slice, chop', group: :sound do
      about <<~TEXT
        Samples are sounds in memory: `Sample['kick.flac']`, `bounce(graph,
        2.bars, bpm:)` (any graph, offline, at its own tempo), or
        `capture_audio(4.bars)` (the master bus or a node, live).  Cut them
        with `rec.slices(16)` (or `slices(:onsets)`), name runs of slices
        (`brk.name(k: 0..1, s: 4..5)`), and edit them as values: `.rev`,
        `.at(7.n16)` (a tracker's 9xx offset), `.looped`, `.bits(12)`,
        `.lofi(:s950)`, `.stretch(1.25)`.  `brk.chop(:k, T, :s, [:s, 2],
        brk[:s].rev)` writes a chop clip: keys of `brk.keymap` (slices from
        C2) with a pitch mark on each hit, so `amen.transpose(2)` pitches
        every hit and a keyboard plays the same slices.  `brk.keymap(split:
        C4)` plays the last slice chromatically above C4.  Play with
        `clip.sampler(brk)` (one truncating voice), `sample.play(v)` in a
        synth, `sfz(path)` and `sf2(path, preset)` instruments (`help
        :soundfonts`), or `sample.node`.  A synth that runs out of voices
        steals one, fading it over 3 ms from the steal (`steal_fade: 10.ms`
        for longer; `sample.play(v, steal_fade: false)` or `.sampler(brk,
        voices: 3, steal_fade: false)` lets it ring on under the new notes).

        Converters: `.lofi(:mpc60)` is the cleanest (40 kHz, filtered: grit
        that sits in a mix), `:s950` darker (31.25 kHz, the jungle
        classic), `:sp1200` the dirtiest (26 kHz, no filters: crunchy hats);
        a whole song often wants none.  `:mpc60` reads clean
        (band-limited, interpolated); `:s950` and `:sp1200` read
        drop-sample with no band-limited levels, aliasing as hits pitch up
        like the hardware (`read: :clean` / `read: :drop`, or
        `.read_as(...)`, says otherwise).  `.stretch(2, cycle: 30.ms)` is
        the S950's cyclic stretch with each cycle fitted to the sound
        (whole periods, matching splices), so tones keep their pitch;
        `fit: :fixed` is the plain version (a buzz at 1 / cycle, stutter
        on breaks, and basses that sound lower).  Both crossfade 3 ms
        between cycles (`crossfade: 0` for the raw splices).  `mode: :spectral` and
        `mode: :paul` stretch in the frequency domain, and `.grains` plays
        a sample as a grain cloud: see `help :granular`.
      TEXT
      commands :bounce, :capture_audio, :chop, :sampler, :sfz
      dsl :bounce
      note :sampler
      see :drums, :sequences, :granular
      example 'a chopped break' do
        rec = bounce(2.bars, bpm: 138.75) {
          tr808(grid(16, kick: 'X.....x...X.....|X.x.......X..x..', snare: '....X..3.3..X..3|.3..X..3....X.3.', hat: 'x.x.x.x.x.xxx.x.|x.x.x.x.x.x.x.xx'))
        }
        brk = rec.slices(32).name(k: 0..1, h: 2..3, s: 4..5, g: 7)
        bg :try, brk.chop(:k, T, :h, :g, :s, T, [:g, 2], :k, T, :k, :h, T, :s, T, [:s, 3], brk[:s].rev).loop.transpose(3).sampler(brk).at(-14.db)
      end
      example 'a resampled bass, looped' do
        bass = 55.hz.ramp.lp4(700, resonance: 0.3).bounce(1.beat, root: A1).looped(0.1..0.4, mode: :ping_pong)
        bg :try, seq(A1, C2, E1, G1).n4.loop.sampler(bass).at(-12.db).until(2.bars)
      end
    end

    Help.topic :soundfonts, 'SoundFonts (.sf2)', group: :sound do
      about <<~TEXT
        `font = sf2('GM.sf2')` opens a SoundFont 2 file; `font.presets`
        lists its presets (bank:program name).  Choose one with
        `sf2('GM.sf2', 0)` (a GM program in bank 0: 0 is the piano),
        `sf2(path, preset: 'Strings')` (a name, or the one name containing
        it), `sf2(path, preset: [128, 0])` (bank 128: GM drum kits), or
        `font[48]`, `font['Pad']`, `font[128, 0]`.  Each is a sampler
        Instrument: `synth(midi) { |v| piano.play(v) }`,
        `beat.sampler(kit, voices: 8)`, or a track's patch.  Only the
        chosen preset's samples are read (a 30 MB GM font opens in a few
        hundredths of a second).

        What carries over: key and velocity zones, root keys and tuning,
        loops, stereo pairs, pans, attenuation, the volume envelope,
        filters, the modulation envelope and LFOs (to pitch, filter, and
        volume), the mod wheel and aftertouch vibrato (`wheel: false`
        leaves it out), and per-zone settings (each note gets its own
        zone's envelope and filter; overlapping zones play as layers,
        each sleeping in synth voices while it has no zone for the note),
        and exclusive classes (a drum kit's closed and pedal hats cut its
        open hat over 3 ms in synth voices; `i.region(s, choke: :hat)`
        does the same in your own instruments, `group:`/`off_by:` like
        SFZ).  What doesn't (extra modulators, ROM samples) is listed once
        per preset when it loads.  Levels follow FluidSynth's
        attenuation scale (`attenuation: 1.0` for the specification's).
        `mips: :default` reads smoother tables (more memory) than the
        `:octave` default.
      TEXT
      commands :sf2, :soundfont
      see :sampler, :sequences
    end

    Help.topic :loops, 'Loop files and tempo-following loops', group: :sound do
      about <<~TEXT
        Loop libraries: `Sample['Funk/break_98bpm.wav']` reads a loop with
        its metadata: ACID chunks (tempo, beats, meter, root, one-shot),
        `smpl` (root, loop points), cue points (`sample.markers`), FLAC
        tags, then tempo and key words in file and folder names ("98bpm",
        "98 BPM", "Am_120"; a name's tempo counts only when the file is a
        whole number of its beats).  Loops loop the whole file; one-shots
        (ACID's flag, words like kick or hit, short files, one hit
        decaying away) keep no name tempo.  `sample.bpm`, `.beats`,
        `.bars`, `.key`, `.meta_source` and `.meta[:why]` (where each came
        from, and why); `Sample[path, detect:
        true]` (or `.detect_tempo`) finds a missing tempo.  `loops
        '~/Loops/Funk'` lists a folder (headers and names only, nothing
        decoded or written), filtered by `bpm: 90..100`, `key: :Am`,
        `beats: 8`; `list[3].sample` reads one.

        `sample.follow` plays a loop in time with the session: its beats
        fill the same span at any tempo, lined up with bar 1 (`align:
        :launch` counts from the launch), restretched when `bpm` changes.
        `follow` keeps the pitch: drums with the slice stretch, notes and
        pads with the phase vocoder (`sample.material` decides from name
        words or how noisy it sounds; `stretch: :slice` or `:spectral`
        to say); `follow(:resample)` lets the pitch follow
        the tempo like a varispeed.  `.stretch(r, mode: :slice)` cuts at
        the hits (markers, else onsets, else the 16th grid) and starts
        each slice at its stretched time, attacks copied exactly:
        slowing down leaves REX-style gaps (`fill: :stretch` draws each
        decay out instead), speeding up truncates with a 4 ms fade.
      TEXT
      commands :loops
      dsl :follow
      note :loops
      see :sampler, :granular, :tempo
      example 'a break that follows the tempo' do
        brk = bounce(2.bars, bpm: 100) { tr909(grid(16, kick: 'X...x...x..xx...', clap: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.', oh: '..x...x...x...x.')) }
        bg :try, brk.follow.at(-16.db).until(2.bars)
      end
      example 'slice stretch vs varispeed' do
        brk = bounce(1.bar, bpm: 100) { tr909(grid(16, kick: 'X..x..X...X.....', snare: '....X.......X..x', hat: 'xxxxxxxxxxxxxxxx')) }
        bg :try, (brk.follow * 0.5 + brk.follow(:resample).pan(0.6) * 0.5).at(-14.db).until(2.bars)
      end
    end

    Help.topic :granular, 'Grains and spectral stretch', group: :sound do
      about <<~TEXT
        `sample.grains(...)` plays a Sample as a cloud of short windowed
        grains (a stereo bundle): `density:` grains per second, `size:`
        (100 ms), `position:` 0..1 (a number freezes, a node or knob
        scrubs), `scan:` (a moving playhead: 0.25 is a 4x granular
        stretch; 1 when no position is given), `spread:`, `pitch:`
        (semitones, or an Array to pick from: `[0, 12, 19]`),
        `pitch_spread:`, `pan_spread:`, `reverse:` (a chance), `window:`
        (:hann, :expodec for percussive grains, ...), `jitter:` (0 regular,
        1 Poisson), `seed:`, `read: :drop` for lofi reads.  Every option
        takes a number, a knob, or a node.  In a synth, `v.grains(pad,
        ...)` tracks the keys.  `max_grains:` caps the cost (32 for a
        cloud, 16 per synth voice): about 3% of realtime for a full mono
        cloud of 32, 6% stereo.

        Stretching keeps the pitch: `.stretch(4)` is the cyclic S950
        stretch (gritty; 3 ms `crossfade:` between cycles),
        `.stretch(4, mode: :spectral)` a phase vocoder with locked phases
        and sharp transients that land on the stretched beat (pads,
        chords, voices, bass, breaks), `.stretch(32, mode: :paul)`
        Paulstretch (endless washes).  They are one algorithm:
        `randomize:` 0..1 goes from the vocoder (0) to Paulstretch (1)
        (`mode: :spectral, randomize: 1`: Paulstretch phases in the
        vocoder's shorter 4096-sample window), with `window:`,
        `overlap:`, `shape: :paul` (the original's window), and `link:
        false` (random phases per channel) for both; for voices try the
        original's settings: `.stretch(8, mode: :paul, overlap: 2,
        shape: :paul, link: false)`.
        They are offline edits: a new Sample, made once; results over 30
        s read with `mips: :octave` (smaller playback tables).
      TEXT
      dsl :grains, :stretch
      note :granular
      see :sampler, :random
      example 'a frozen pad' do
        pad = bounce(1.bar) { (220.hz.ramp + 277.2.hz.ramp + 330.hz.ramp).lp4(1800) * 0.3 }
        bg :try, pad.grains(position: 0.5, size: 150.ms, density: 30, spread: 0.05, pitch: [0, 12], pan_spread: 0.8).at(-16.db)
      end
      example 'a 4x spectral stretch' do
        riff = bounce(1.bar) { seq(A3, C4, E4, G4).n8.loop.then { |c| c.tone.ramp.lp4(1500) * c.amp_env } }
        bg :try, riff.stretch(4, mode: :spectral).node.at(-12.db)
      end
      example 'Paulstretch phases in the vocoder (randomize: 1)' do
        riff = bounce(1.bar) { seq(A3, C4, E4, G4).n8.loop.then { |c| c.tone.ramp.lp4(1500) * c.amp_env } }
        bg :try, riff.stretch(8, mode: :spectral, randomize: 1).node.at(-12.db)
      end
      example "a voice Paulstretched the original's way" do
        voice = bounce(1.bar) { seq(A3.n4, C4.n4, E4.n4, D4.n4).legato(1).then { |c| c.tone.ramp.formant(:a, :o) * c.amp_env * 0.5 } }
        bg :try, voice.stretch(8, mode: :paul, overlap: 2, shape: :paul, link: false).node.at(-10.db)
      end
    end

    Help.topic :random, 'Randomness and seeds', group: :sound do
      about <<~TEXT
        Everything random (phases, noise, unison layouts, synth lanes) draws
        from one root generator, so the same seed makes the same sounds.
      TEXT
      commands :seed, :with_seed, :next_seed, :random_seed
      dsl :rnd, :noise, :humanize, :chance
      see :tones
      example 'noise that repeats' do
        seed 42
        bg :try, 1000.hz.noise.lp4(3000).at(-12.db).until(1.bar)
      end
    end

    Help.topic :sequences, 'Clips and sequences', group: :time do
      about <<~TEXT
        Immutable clips in exact whole notes: `seq(C4, E4, G4).n8`,
        `grid('x...')`; a clip is a MIDI source (`clip.tone`, `clip.env`,
        `clip.synth`) and has transforms (transpose, swing, chance, ...).
      TEXT
      commands :seq, :grid, :events, :rest, :euclid, :melody, :acid, :chord, :arp, :strum, :echo, :scale
      dsl :loop, :n8, :n16, :transpose, :swing, :humanize, :chance, :every, :reverse, :halftime, :doubletime, :synth, :tone, :amp_env, :swap
      note :sequences
      see :tempo, :sets
      example 'a looping arpeggio' do
        clip = seq(A3, C4, E4, G4).n16.loop
        bg :try, clip.tone.triangle.at(-12.db) * clip.amp_env
      end
    end

    Help.topic :generative, 'Generative music', group: :time do
      about <<~TEXT
        Probability scales and generator clips.  `scale(:dorian, :d).weights`
        is a probability scale: layer it with `+` and `*`
        (`+ tones(D3, F3, A3) * 2`, or a named chord:
        `+ chord(:min7, root: :d).weights * 2`), `blur(0.2)` it so wrong
        notes sometimes hit, `blend` it toward another key, change it over
        time with `harmony(0 => a, 8.bars => b)` (keys are lengths), and
        spread it over notes with
        `over(A3..A5, around: E5)`.  `melody`, `strikes`, and
        `generate(1.bar) { |cycle, dice| rows }` make looping clips whose
        every cycle is a pure function of the seed and the cycle
        (counter-based `dice`), so they seek, replay in takes, and save.
        `motifs(h, 8, form: %i[a a b a], answer: { b: :a })` remembers its
        phrases: motifs come back (through key changes), `b` answers `a`
        and lands home, repeats vary a little, and every `evolve:` passes
        the motifs mutate a step here and there; `range:`/`around:` set
        the register.
      TEXT
      commands :tones, :chord, :weights, :harmony, :generate, :strikes, :dice, :melody, :motifs
      note :generative
      see :sequences, :random
      example 'a melody that blurs and changes key' do
        h = harmony(0 => scale(:dorian, :d), 1.bar => scale(:major, :f), loop: 2.bars).blur(0.2)
        line = melody(h, 8, range: A3..A5, vary: true).loop
        bg :try, line.synth(voices: 2) { |v| v.hz.triangle * v.env(0.005, 0.2, 0.3, 0.2) }.at(-14.db)
      end
      example 'a tune with phrase memory: a a b a, b answering a' do
        h = scale(:dorian, :d).weights + chord(:min7, root: :d).weights * 1.5
        tune = motifs(h, 8, form: %i[a a b a], answer: { b: :a }, range: A3..A5, around: D4)
        bg :try, tune.synth(voices: 2) { |v| v.hz.triangle * v.env(0.005, 0.2, 0.3, 0.2) }.at(-14.db)
      end
      example 'sparse bells over a drone' do
        bells = strikes(scale(:minor_pentatonic, :a).weights.over(A4..A6), every: 1.n8, chance: 0.5, gap: 2)
        bg :try, bells.synth(voices: 4) { |v| v.hz.sine * v.env(0.002, 0.8, 0, 0.8) }.at(-12.db) + 110.hz.triangle.at(-26.db)
      end
    end

    Help.topic :tempo, 'Tempo, tuning, and the timeline', group: :time do
      about <<~TEXT
        One transport for everything: tempo, a meter map, and bar numbers
        that stay stable.  Durations (`1.n8.dotted`, `2.bars`) follow the
        tempo; `1.beat.hz` locks a tone to the beat; `tuning` moves every
        Note.
      TEXT
      commands :bpm, :meter, :rewind, :seek, :bar, :transport, :tuning
      note :tempo_sync, :numbers_lengths_phases
      see :schedule
      example 'a tempo-locked wobble' do
        bg :try, 55.hz.ramp.at(-16.db).lp4(400 + 1.beat.hz.lfo.triangle * 300 + 300).until(2.bars)
      end
    end

    Help.topic :schedule, 'Scheduling', group: :time do
      about <<~TEXT
        Blocks on the Session timeline: commands inside them land exactly at
        the block's time, and each block is one undo step.  `at_bar`,
        `after`, and `every` take launch points too (`at_bar in: 2.beats`,
        `every 1.n4, on: :beat`) and return a handle that prints when it
        runs and has `cancel`.  `reset_scheduler` (or `panic`, which also
        stops the players) cancels everything scheduled, stops a song
        form, and replaces a stuck scheduler.
      TEXT
      commands :at_bar, :after, :every, :scheduled, :cancel, :reset_scheduler, :marker, :at_marker
      note :method_modules
      example 'a note that answers itself' do
        bg :try, 330.hz.triangle.at(-20.db).until(1.bar)
        after(1) { bg :try2, 440.hz.triangle.at(-22.db).until(1.bar) }
      end
      example 'ticks you can cancel' do
        bg :try, 330.hz.triangle.at(-20.db).until(2.bars)
        ticks = every(1.n4, on: :beat) { bg :tick, 880.hz.triangle.at(-26.db).until(1.n16) }
        after(1) { ticks.cancel }
      end
    end

    Help.topic :sets, 'Tracks, scenes, and undo', group: :arrange do
      about <<~TEXT
        The Set layer: tracks remember a patch and a clip, scenes are the
        state of every track, `go` launches one at its launch point
        (`on:`, `in:`, `at: bar(n)`).  Every command is one undo step.
        Each track keeps the clips it has played as numbered slots (the
        clip matrix): `launch :bass, :bass_b` (or a slot number) plays one,
        and `tweak :bass, transpose: 2` (legato:, swing:, quantize:,
        :reverse, :halftime, :doubletime, :double, :half) plays a changed
        copy as a new slot.
      TEXT
      commands :track, :tracks, :scene, :scenes, :go, :launch, :tweak, :quant, :undo, :redo!, :changes, :swap
      note :arrangement
      see :flow, :knobs, :now
      example 'two scenes' do
        track(:try_bass, q: 1) { |c| c.tone.ramp.at(-10.db).lp4(500, resonance: 0.3) * c.amp_env }
        scene :try_a, try_bass: seq(A1, rest, A1, A2).n8.loop
        scene :try_b, try_bass: seq(F1, rest, F1, F2).n8.loop
        go :try_a
        go :try_b, in: 1.bar
      end
      example 'launch and tweak a clip' do
        track(:try_bass, q: 1) { |c| c.tone.ramp.at(-10.db).lp4(500, resonance: 0.3) * c.amp_env }
        bg :try_bass, seq(A1, rest, A1, A2).n8.loop.named(:try_riff)
        tweak :try_bass, transpose: 12
        launch :try_bass, :try_riff, in: 1.bar
      end
    end

    Help.topic :flow, 'Song forms', group: :arrange do
      about <<~TEXT
        `flow do intro 4; verse 8; ... end` plays sections (scenes of the
        same name) with labels, gotos, and picks decided at commit points;
        perform it with loop!, onward, goto, skip, finish, practice, seek.
      TEXT
      commands :flow, :play_form, :section, :loop!, :onward, :goto, :skip, :finish, :practice, :seek, :marker, :meter
      note :arrangement
      see :sets
      example 'a tiny song form' do
        track(:try_lead, q: 1) { |c| c.tone.triangle.at(-12.db) * c.amp_env }
        scene :try_intro, try_lead: seq(A4, E4).n4.loop
        scene :try_verse, try_lead: seq(A4, C5, E5, C5).n8.loop
        scene :try_outro, try_lead: seq(A4).n2.loop
        flow do
          try_intro 1
          label :top
          try_verse 2
          goto :top, times: 1
          try_outro 1
        end
      end
    end

    Help.topic :demo, 'A demo set to explore', group: :arrange do
      about <<~TEXT
        `demo` loads a whole set into the session, paused at bar 1: Night
        Bus (bin/songs/night_bus_flow.rb), tech house at 126 BPM with 12
        tracks, 12 scenes, 5 knobs, a master chain, and its song form.
        Nothing plays until you do something: `go :groove` launches a
        scene, `turn :cut, 3000, over: 2` opens the hook's filter, `play_form
        demo.form` plays the whole song (steer it with `loop!`, `onward`,
        `finish`), and `tracks`, `scenes`, `knobs`, `ui :tiles` show what
        is there.  With something already playing, `demo` asks first
        (`demo :night_bus, replace: true` stops it).  `demos` lists the
        sets.  The set is a set document in mb-sound's presets/ (saved by
        bin/save_presets.rb), so `save :mine, set` keeps your changes.
      TEXT
      commands :demo, :demos
      note :arrangement
      see :sets, :flow, :knobs, :presets
      example 'the demo sets', sound: false do
        demos.keys
      end
    end

    Help.topic :genres, 'Genre templates', group: :arrange do
      about <<~TEXT
        `genre :dnb` is a template of a genre: tempo, form, drum grids and
        fills, track roles with suggested presets, scenes, mix targets, and
        tips.  `genre(:dnb).short.play` plays it, `.setup` makes its tracks
        and scenes to play by hand, `.to_ruby` prints it, and a block or
        keywords change any part (:dnb, :jungle, :ambient, :funk; :house and
        :techno are stubs).
      TEXT
      commands :genre, :genres
      note :genres
      see :flow, :sets, :presets
      example 'a genre in numbers', sound: false do
        t = genre(:jungle)
        [t.tempo, t.form.steps.first(3), t.roles.keys, t.mix.summary]
      end
    end

    Help.topic :knobs, 'Knobs and snapshots', group: :perform do
      about <<~TEXT
        Named values that graphs read (`knob(:cut)`) and you turn, with
        ramps, launch points, MIDI learn, snapshots, and crossfades.  Turns
        are journaled and undoable.
      TEXT
      commands :knob, :knobs, :turn, :snap, :snaps, :recall, :xfade, :learn
      note :arrangement
      see :sets, :now
      example 'a filter knob' do
        knob :try_cut, 400, range: 100..8000, curve: :exp, unit: 'Hz'
        bg :try, 55.hz.ramp.at(-14.db).lp4(knob(:try_cut), resonance: 0.5)
        turn :try_cut, 4000, over: 2.bars
      end
    end

    Help.topic :mixing, 'Mute, solo, master', group: :perform do
      about <<~TEXT
        Mute and solo with a 5 ms declick or synced fades (muted players
        sleep); master effects run on the whole mix and swap at launch
        points.  The master gain comes before the master chain (a limiter
        keeps its ceiling); `master_gain 2.db, post: true` moves it after.
      TEXT
      commands :mute, :unmute, :solo, :unsolo, :mutes, :master, :master_gain, :monitor_gain
      note :arrangement, :master_effects
      see :buses, :dynamics, :mastering
      example 'a quick master chain' do
        bg :try, 110.hz.saw.at(-20.db).until(2.bars)
        master { |mix| mix.softclip.limit(ceiling: -1.db) }
        after(3) { master nil }
      end
    end

    Help.topic :mastering, 'Mastering presets and loudness targets', group: :perform do
      about <<~TEXT
        `master :club` (also :streaming, :quiet, :vinyl) ends the master
        chain with a mastering preset: mono lows, glue, limiter, and a
        loudness target.  Renders reach the target exactly (two passes);
        live, `ride: true` rides the gain toward it.  `masters` lists them,
        `master(:club) { |mix| fx }` puts your effects first, and
        `render 'x.flac', master: :streaming { song }` or a song's
        `--master club` masters any song.
      TEXT
      commands :masters, :master, :render
      dsl :master, :ride
      note :master_effects, :dynamics
      see :mixing, :loudness
      example 'a preset at the listening level (drive: keeps the level fixed)' do
        bg :try, 110.hz.saw.at(-20.db).until(2.bars)
        master :quiet, lufs: -35, drive: 0.db
        after(3) { master nil }
      end
    end

    Help.topic :buses, 'Buses, sends, sidechains', group: :perform do
      about <<~TEXT
        Named buses with their own effects: tracks send a level to them
        (`send:`, `feed`) or play all of their sound into them (`to:`): one
        kind of bus for reverbs, groups, and returns alike.  They ring out on their own,
        sleeping when quiet.  `duck(:drums, only: :kick)` and `bus(:drums)`
        read a bus or track by name on the exact sample.  Buses mute and
        solo like tracks (a solo keeps the buses it feeds).
      TEXT
      commands :bus, :buses, :feed, :routes
      dsl :duck, :compress
      note :buses
      see :mixing, :dynamics
      example 'a shared reverb send' do
        bus(:try_verb) { |sig| sig.reverb(:room, mix: 1) }
        bg :try, seq(A3, C4, E4, rest).n8.loop.tone.triangle.at(-20.db).until(1.bar), send: { try_verb: -6.db }
      end
      example 'duck a pad by the kick of a drum track' do
        track(:try_drums) { |k| tr808(k).at(-14.db) }
        bg :try_drums, grid(16, kick: 'x...x...x...x...').loop
        bg :try, 110.hz.saw.at(-24.db).lp4(900).duck(:try_drums, only: :kick).until(1.bar)
      end
    end

    Help.topic :racks, 'Racks: reusable graphs with typed ports', group: :perform do
      about <<~TEXT
        A rack is a piece of graph you can reuse, like a Proc: `mrack` takes
        notes, `irack` notes and makes audio, `arack` audio, `lrack` audio
        and makes notes or control, `modrack` control (`rack(in:)` is the
        general form).  Apply it with `then`, `.()`, or `through`; each use
        builds a fresh copy.  Extra ports are keywords (`arack :dub, side:
        :audio do |sig, side:|`), bound with `with` (bus, track, and knob
        names work as values).  `>>` chains racks; note streams merge with
        `+`.  Named racks list in `racks` and print with `rack(:x).to_ruby`.
        `knob :space, 0.3` inside a rack block is a knob scoped to the rack
        (`turn :"dub/space", 0.6`; per player, `:"bass/dub/space"`, when the
        rack plays in several, and `:"dub/space"` turns them all); `share: true` joins the session knob
        `:space`, `follow: :space` maps it onto this knob's range, and
        `.mod(lfo, depth: 0.2)` swings around it.  `rack(:dub).snap :wide`
        and `recall :"dub/wide", only: [:space]` keep variations.  `help
        rack(:dub)` shows ports, knobs, and latency.  `save :dub,
        rack(:dub)` writes a rack document: `preset :dub` gives the rack
        back, `preset :dub, sig: mic` plays it on an input (try the library
        rack `preset :dub_echo`); a saved rack that differs from the
        session's asks, or takes `racks: :session`, `:saved`, or `:rename`.
      TEXT
      commands :rack, :racks, :mrack, :irack, :arack, :lrack, :modrack
      note :racks
      see :buses, :midi, :presets
      example 'a note rack: an anonymous value' do
        wobble = mrack { it.arp(:up, 16).echo(3.n16, 2, pitch: 7) }
        bg :try, seq(A3, C4, E4, G4).n4.loop.then(&wobble).synth { |v| v.hz.triangle.at(-17.db) * v.amp_env(0.005, 0.1, 0.3, 0.1) }.until(1.bar)
      end
      example 'an effect rack with a sidechain port' do
        arack(:try_pump, side: :audio) { |sig, side:| sig.duck(side, amount: 12.db, threshold: -24.db).softclip }
        track(:try_kick) { |k| tr808(k).at(-14.db) }
        bg :try_kick, grid(16, kick: 'x...x...x...x...').loop
        bg :try, 55.hz.saw.at(-24.db).lp4(700).then(&rack(:try_pump).with(side: :try_kick)).until(1.bar)
      end
    end

    Help.topic :midi, 'MIDI', group: :perform do
      about <<~TEXT
        `midi` is a Notes on live input; `synth` allocates voices from any
        MIDI source; transforms (echo, arp, chord, strum, ...) work on
        Streams, Notes, and Clips; mod_sum and friends route modulation.
        Stuck note on live input (a keyboard dropped a note-off)?  Press
        the key again and let go: live input restrikes held keys
        (`same_key: :restrike`; files and clips count overlaps,
        `same_key: :count`).
      TEXT
      commands :midi, :midi_file, :midi_stream, :synth, :per_voice, :close_midi, :mod_sum, :mod_scale
      dsl :gate, :trigger, :velocity, :amp_env, :hz, :cutoff, :reso, :arp, :echo, :chord
      note :midi
      see :record
    end

    Help.topic :key, 'The session key and modes', group: :time do
      about <<~TEXT
        The session has a key: `key :ab` sets the root (also 'F#', a Note
        like Ab2, or 0..11), `mode :phrygian` the scale (any scale name),
        `key :d, :dorian` both, and bare `key` / `mode` read them back.
        Changes take launch points (`mode :lydian, on: :bar`), work in
        scheduled blocks, scenes (`scene :drop, key: [:a, :minor]`), and
        sections (`drop 8, key: :d, mode: :dorian`), and are undoable.
        `scale(:dorian)` without a root uses the key's root; bare `scale`
        is the key's scale; `degrees`, `snap`, and `lock` follow the key
        as it changes.  `mode knob(:dark)` walks the modes from Lydian to
        Locrian, one note at a time (`modes(:dorian..:phrygian, by:
        knob(:dark))` for part of the walk).
      TEXT
      commands :key, :mode, :modes, :scale
      dsl :degrees, :snap, :lock
      note :midi
      see :lock, :params, :sequences
      example 'a riff that follows the key' do
        key :d, :dorian
        riff = seq(C4, D4, E4, G4, A4, G4, E4, D4).n8.loop
        bg :try, riff.stream.lock(:play).synth(voices: 4) { |v| v.hz.triangle * v.env(0.005, 0.2, 0.3, 0.2) }.at(-14.db)
        mode :lydian, on: 2
      end
    end

    Help.topic :lock, 'Keyboard locks: play in key', group: :perform do
      about <<~TEXT
        `lock :play` maps live MIDI and the virtual keyboard into the
        session key: the root on every C, black keys passing notes between
        their neighbours.  `lock :mash` makes every white key the next
        scale degree and silences black keys (mash anything), `lock
        :along` snaps each key to the nearest scale note, `lock :chord`
        plays the current chord's tones (`from:` a clip of chords or
        degrees like [1, 6, 4, 5]; `extend: :above` stacks 7ths and 9ths
        above the chord, `bass: :root_fifth` below it), `lock :off`.
        Keywords override one option (`lock :chord, extend: true`), and
        streams take the same styles: `riff.stream.lock(:mash)`,
        `midi.degrees(:minor_pentatonic, layout: :fit)`, `midi.snap(:chord,
        from: chords)`.  A knob can pick the style: `lock
        knob(:style).choose(:mash, :play, :chord)`.
      TEXT
      commands :lock, :key
      dsl :degrees, :snap
      note :midi
      see :key, :midi, :ui
      example 'the same keys in three locks' do
        key :a, :minor
        keys = seq(48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59).n16.loop
        voice = proc { |v| v.hz.triangle * v.env(0.003, 0.15, 0.2, 0.1) }
        bg :try, keys.stream.lock(:mash).synth(voices: 4, &voice).at(-14.db)
        bg :try2, keys.stream.lock(:chord, from: [1, 6]).transpose(12).synth(voices: 4, &voice).at(-20.db)
      end
    end

    Help.topic :params, 'Parameters that move', group: :perform do
      about <<~TEXT
        MIDI transforms read moving parameters at each decision (each
        note-on, arp step, or bar): `cc(1, 0.5..0.7)` (a controller on the
        transform's own input, else the session's MIDI input), knobs
        (`knob(:swing)`, `knob(:rate).choose(8, 16, 32)`), tempo LFOs
        (`4.bars.lfo.at(0.5..0.66)`), clips (`transpose(seq(0, 5, -2,
        3).n1.loop)`: a step per bar), and arithmetic on them (`0.5 +
        cc(1) * 0.2`), all printing back as Ruby.  humanize, quantize,
        swing, chance, transpose, every, arp rates, and ratchets take them,
        on streams and clips.  A knob read ahead (a generator's next cycle)
        answers what is known when it is asked, including turns queued with
        launch points; takes record those answers so replays match.
      TEXT
      commands :cc, :knob, :modes
      dsl :swing, :humanize, :chance, :transpose, :arp, :ratchet, :every, :quantize
      note :midi
      see :knobs, :key, :sequences
      example 'swing that breathes and a transpose by a clip' do
        riff = seq(A3, C4, E4, G4, A4, G4, E4, C4).n16.loop
        steps = seq(0, 5, -2, 3).n1.loop
        bg :try, riff.stream.swing(4.bars.lfo.triangle.at(0.5..0.68)).transpose(steps).synth(voices: 4) { |v| v.hz.triangle * v.env(0.003, 0.2, 0.2, 0.1) }.at(-14.db)
      end
      example 'an arp whose rate a knob picks' do
        knob :try_rate, 0
        chords = (seq(A3, F3).n1 & seq(C4, A3).n1 & seq(E4, C4).n1).loop
        bg :try, chords.stream.arp(:up, knob(:try_rate).choose(8, 16, 32)).synth(voices: 4) { |v| v.hz.triangle * v.env(0.003, 0.1, 0.2, 0.05) }.at(-14.db)
        turn :try_rate, 1, over: 2
      end
    end

    Help.topic :record, 'Recording and takes', group: :keep do
      about <<~TEXT
        The take logs every line and where each change landed (`take.save`
        replays it exactly).  `rec`/`capture` record MIDI into armed tracks
        (loops follow the timeline's phase; `align: :launch` starts from
        what you played first); an armed track's live monitor is its own
        player, :"name/live", which `stop :name` leaves playing and
        `disarm` stops.  `rec_audio` records the master bus to a file;
        `render` bounces graphs offline (`render 'drop.flac', from: :drop,
        bars: 8 { song }` renders one section, exactly as in the whole
        song; scripts take `--from drop --to breakdown`, and `--take
        take.rb` saves a run as a replay script).  No MIDI keyboard?  The tiles'
        virtual keyboard (`ui.keys`, see `help :ui`) plays into the same
        input, and Enter there captures.
      TEXT
      commands :take, :arm, :disarm, :armed, :rec, :capture, :captures, :rec_audio, :stop_rec_audio, :recordings, :render, :write
      note :arrangement
      see :midi, :presets
    end

    Help.topic :presets, 'Saving graphs and sets', group: :keep do
      about <<~TEXT
        Every graph prints itself back as Ruby (`ruby node`); `save` writes a
        graph document (or the whole set), `preset` loads one with new
        inputs and params.  mb-sound comes with presets too (`presets`
        lists them): drum & bass, jungle, ambient, and funk instruments,
        like `preset :dnb_reese, midi: midi` or `preset :ambient_tape, input: mic`,
        and electric pianos: `:tine_piano` clean, `:tine_crunch` with its amp
        pushed (`amp: 1..8`), `:reed_piano`, and the SQ-80 voice's patches
        (`:sq80_glass` and friends; see `help :sq80`).
      TEXT
      commands :ruby, :save, :preset, :presets, :set, :named_proc
      note :graph_io
      example 'print a graph back as Ruby', sound: false do
        ruby 110.hz.saw.at(-20.db).lp4(800, resonance: 0.3).softclip
      end
    end

    Help.topic :plots, 'Plots', group: :look do
      about <<~TEXT
        Pure-Ruby plots in the terminal (Braille, blocks, sparklines) or as
        images: waveforms, spectra, spectrograms, histograms, and chart
        builders; `vis` plots the live mix.
      TEXT
      commands :plot, :spectrum, :spectrogram, :time_freq, :hist, :density, :mag_phase, :overlay, :overlay_chart, :table, :chart, :figure, :vis
      note :plotting
      example 'one cycle of a pulse', sound: false do
        plot 100.hz.pulse, samples: 480
      end
    end

    Help.topic :analysis, 'Analysis', group: :look do
      about <<~TEXT
        Pitch, peaks, and correlation of sounds and arrays, and the form of
        a render or a file (tempo, beats, bars).
      TEXT
      commands :freq_estimate, :peaks, :autocorrelate, :crosscorrelate, :peak_correlation, :analyze_form, :loudness
      note :structure
      see :loudness, :plots
    end

    Help.topic :loudness, 'Loudness', group: :look do
      about <<~TEXT
        BS.1770 loudness of files and graphs, live meters, and normalized
        renders.  `render 'mix.flac', bars: 64, report: :tracks { song }`
        (scripts: `--report`) prints LUFS, short-term max, true peak, and
        PLR per track and the mix, and each section pass's loudness.
      TEXT
      commands :loudness, :render
      dsl :loudness_meter
      note :method_modules, :dynamics
      see :mastering
    end

    Help.topic :now, 'Help and what is going on', group: :look do
      about <<~TEXT
        `now` shows what plays, knobs, scenes, the flow, and queued changes
        with the commands that apply; `help node` explains a graph;
        `lesson` teaches the newer layers step by step.  When something
        goes wrong live, `debug_dump` writes the state (players, changes,
        graphs as Ruby, the screen, the take, recent MIDI, threads) to a
        folder to read or send along.
      TEXT
      commands :help, :now, :lesson, :players, :knobs, :scenes, :tracks, :mutes, :changes, :markers, :ruby, :debug_dump
      see :sets, :knobs, :ui
    end

    Help.topic :ui, 'Dashboard band and tiled screen', group: :look do
      about <<~TEXT
        `ui` puts a live dashboard band under the prompt (transport, form,
        tracks, queued changes, master meters, a scope); Pry keeps the rest
        of the screen, and scrolled lines stay in the terminal's scrollback.
        `ui :deck` adds knobs and CPU, `ui :mini` is one line, `ui off`
        hides it.

        `ui :tiles` (or `:studio`, `:keys`, `:wall`) takes the whole screen:
        panes tiled around the console, which keeps a 10 000-line scrollback
        of its own.  Ctrl-] is NAV mode (`?` there lists its keys): numbers
        and arrows pick a pane, Enter goes into it (the REPL, KEYS on the
        keyboard, a pane's own keys until Esc), and a pane's letter beside
        its number jumps straight in (i the REPL, k the keyboard, a the
        clips).  Ctrl-W is NAV for one key: Ctrl-W z zooms and comes back,
        Ctrl-W a goes into the clips, Ctrl-W Ctrl-W swaps between the last
        two panes, Ctrl-W Ctrl-] stays in NAV.  F2 or
        `keys` is the keyboard, Ctrl-Z hides the tiles while the set plays
        on (`fg` brings them back, `jobs` lists what runs).

        Warnings go to a messages pane while a screen is up (NAV m shows
        it; `ui off` sums them up).  NAV f shows the frame rate and each
        pane's rate beside its number (`ui.fps` is what was drawn,
        `ui.target_fps` the painter's rate; meters and scopes run at it and
        everything slows in steps when the CPU is busy).

        Your own panes: `pane :name do |c, s| ... end` (s a snapshot of the
        session, c the pane's canvas); arrange them with `layout`, keep a
        layout with `ui.save`.  `ui.split :v`, `ui.zoom`, `ui.show :cpu`,
        `ui.save :mine` change the tiles from the prompt; `ui.on C1, :zoom`
        maps a pad; `ui.theme :mono`.  Themes, pane files, and layouts are
        data files in the ui folder, reloaded when they change;
        `bin/ui_check.rb` reports what your terminal supports.

        The keyboard plays notes into the session's MIDI input, so
        `arm :lead` plays the lead and Enter captures what you just played
        into it (with nothing armed a default patch plays).  Most terminals
        send no key-up, so notes are a fixed length there
        (`ui.keyboard.tap = 0.5`); with the kitty keyboard protocol (kitty,
        WezTerm, Ghostty, foot, iTerm2 with its setting) they end on
        key-up.  Tab is step entry: Enter puts the clip's Ruby
        (`seq(C3, E3, G3.n4).n8`) on the console line.  Notes from a MIDI
        keyboard light the piano too, in a second color.

        `ui :session` shows the set: the clip matrix (`clips`: a row per
        track, a column per scene, then each track's other slots; ▶ plays,
        ◆ is queued with its countdown in beats), the clip under its cursor
        (`clip`: a piano roll and the Ruby that made it), racks with their
        knobs, buses with meters.  Focus a pane in NAV (its number, or a
        for clips, r racks, b buses) and press Enter for its keys: arrows
        move, Enter launches the cell (`launch :bass, 3`), g its scene (`go
        :drop`), x stops the track, + - > < transpose, L legato, S swing, Q
        quantize, D double, H half, R reverse (`tweak :bass, transpose: 1`),
        u undo; in racks Left/Right turn the picked knob (Shift: fine).
        Every key runs one console line, printed in the console: journaled,
        undoable, in your take.  `ui :mixer` shows buses beside the master.
      TEXT
      section do |d|
        rows = UI.layout_table.map do |name, kind, desc, size, panes, current|
          label = "#{current ? '* ' : ''}#{kind == :script ? '--ui' : 'ui'} #{name.inspect}"
          what = "#{desc}#{size ? " (#{size})" : ''}. #{kind == :band ? 'Band' : kind == :script ? 'Script screen' : 'Tiles'}: #{panes.join(' ')}"
          [label, what]
        end
        d.heading('Layouts  (* on screen now)').rows(rows, max_label: 18, wrap: true)
      end
      section do |d|
        # (The pane catalog, ui.panes: ux-1 r3 item 40)
        d.heading('Panes  (ui.panes; ui.list: what is on screen; ui.size)')
        d.rows(UI.pane_catalog.entries.map { |e| [e.name.inspect, "#{e.description} (#{e.open})"] }, max_label: 12, wrap: true)
        d.heading('Sizes  (one decision per terminal size: UI::Density)')
        d.rows(UI::Density.table.map { |t| t.split(': ', 2) }, max_label: 20)
      end
      section do |d|
        UI::Tiles::KEY_HELP.each do |mode, groups|
          groups.each do |group, keys|
            d.heading("#{group} keys  #{Help::Text.c(:dim, { nav: '(NAV: Ctrl-])', grab: '(KEYS: F2, keys)', step: '(step entry: Tab in KEYS)' }[mode])}")
            d.rows(keys, max_label: 20)
          end
        end
      end
      commands :ui, :off, :pane, :layout, :keys, :fg, :jobs
      note :terminal_ui
      see :now, :plots
    end
  end
end
