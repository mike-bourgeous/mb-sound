module MB
  module Sound
    module Genre
      # Small patches that genre templates' roles use where no preset fits
      # (role patches name a preset first, then these, then MB::Sound
      # methods).  Each takes the role's MIDI source first.
      module Patches
        module_function

        # A noise riser that ignores its notes: a resonant bandpass sweeping
        # up from +from+ to +to+ Hz over +bars+ bars from the track's launch,
        # swelling to +level+ (from "Tunnel Vision"'s riser).  Give its role
        # a short fade: so a scene change takes it away cleanly.
        def riser(_source, bars: 4, from: 250, to: 10000, level: 0.25)
          sweep = MB::Sound.tween([from, to], bars.bars, log: true, loop: false)
          MB::Sound.noise.filter(:bandpass, cutoff: sweep, quality: 3) * MB::Sound.tween([level * 0.12, level], bars.bars, loop: false)
        end

        # A chopped break: plays +source+, a chop clip of a break's slices
        # (`brk.chop(:k, T, [:s, 2], brk[:s].rev)`, which knows what plays
        # it: Sequence::PlayedBy), on one truncating sampler voice (each hit
        # cuts the last through a 1.3 ms declick), velocity 0.75 (MIDI 95)
        # as cut, then the S950-ish output stage of Nev Ashdown's jungle
        # sampler (bin/synths/jungle.rb): a 13 kHz lowpass, +grit+ of
        # sample-rate reduction to 30 kHz, a lowpass at +cutoff+ (a number
        # or a node such as a knob), and a little tape saturation, times
        # +level+.  Other sources (live MIDI, plain clips) play the 32
        # sixteenths of breakbeat(:jungle) from C2.  (genre-fixes, 2026-10-18: the jungle template's chops,
        # replacing the key-zone notes of the jungle_breaks preset.)
        def breaks(source, cutoff: 16000, grit: 0.25, level: 1.6)
          slices = source.respond_to?(:instrument) && source.instrument
          slices = MB::Sound.breakbeat.slices(32) unless slices.respond_to?(:sampler)
          slices.sampler(source) { |v, s| s * v.env(0.0005, 0.01, 1, 0.006, gm: false) * (v.velocity * (1 / 0.75)) }
            .filter(:lowpass, cutoff: 13000, quality: 0.6)
            .decimate(30000, mix: grit)
            .filter(:lowpass, cutoff: cutoff, quality: 0.9)
            .softclip(0.6, 0.98) * level
        end

        # Rain that ignores its notes (play it on a looping rest clip):
        # per side, a bed of pink noise through a bandpass that wanders
        # (drift) between 600 and 1700 Hz, a little hiss above 6.5 kHz, and
        # drops: +density+ random impulses a second (dust, at least 4 ms
        # apart) each pinging a resonance at its own pitch (2.6-3.5 kHz)
        # for 20 ms, the whole swelling with slow gusts.  +level+ may be a
        # node (a knob: louder rain is denser too).  Stereo, the sides
        # independent.  (genre-fixes, 2026-10-18: the ambient template's
        # weather, after bin/songs/tin_roof.rb's rain.)
        def rain(_source, level: 0.5, density: 70)
          side = -> {
            bed = MB::Sound.noise(:pink).filter(:bandpass, cutoff: MB::Sound.drift(0.31, range: 600..1700), quality: 0.9) * 0.35 +
              MB::Sound.noise.filter(:highpass, cutoff: 6500, quality: 0.5) * 0.03
            drops = MB::Sound.dust(density, min_gap: 0.004)
            pitch = MB::Sound.noise.sample_hold(drops) * 450 + 3050
            gusts = MB::Sound.drift(0.07, range: 0.55..1.0)
            (bed + drops.ping(pitch, decay: 0.02) * 0.5) * gusts
          }
          MB::Sound.stereo(side.(), side.()) * level
        end

        # Wind that ignores its notes: per side, brown noise through a
        # bandpass wandering between 220 and 800 Hz (drift), its level
        # rising and falling in gusts of several seconds, times +level+ (a
        # number or a knob).  Stereo, the sides independent.  (genre-fixes:
        # the ambient template's weather.)
        def wind(_source, level: 0.5)
          side = -> {
            cut = MB::Sound.drift(0.11, range: 220..800)
            gusts = MB::Sound.drift(0.17, range: 0.15..1.0, smooth: :cubic)
            MB::Sound.noise(:brown).filter(:bandpass, cutoff: cut, quality: 1.6) * gusts
          }
          MB::Sound.stereo(side.(), side.()) * level * 10
        end

        # Tape hiss that stops with the sound (a bus effect: +input+ is the
        # bus input, a bundle): the input plus pink hiss above 2.5 kHz at
        # +level+ (a gain), gated by `input.sounding` (open while the input
        # is above -90 dB, held 1 s and faded over 0.3 s after), so the
        # hiss ends with the weather.  Each channel hisses on its own.
        # (genre-fixes: the ambient template's :weather bus; the
        # ambient_tape preset does this with wow and wear too, but costs
        # 27% of realtime per stereo 800-frame buffer, this ~1%.)
        def hiss(input, level: -42.db)
          chans = input.respond_to?(:outputs) ? input.outputs : [input]
          noises = chans.map { MB::Sound.noise(:pink).filter(:highpass, cutoff: 2500, quality: 0.6) * level }
          gate = input.sounding(hold: 1, fade: 0.3)
          (input + MB::Sound.channels(*noises) * gate).ring(:first)
        end

        # A house bass, half way between Munro's "one saw with a tempo-set
        # decay" (genre-fixes) and the funk_bass preset the house stub
        # played before it (the maintainer on the genre-fixes Bench: "Before
        # bass is better; maybe go half way between the two";
        # bench-fixes-1, 2026-10-18).  One voice: a saw through a four-pole
        # lowpass at +cutoff+ Hz opened +env+ octaves by a filter envelope
        # (+filter_decay+ s down to +filter_sustain+), plus a sine +body+ at
        # the note's pitch (relative to the saw), a level envelope decaying
        # over +decay+ (a length: a dotted eighth by default, so it follows
        # the tempo) to +sustain+, a little velocity, and a soft clip.
        # Half way, setting by setting (funk_bass -> Munro): body 1.45 ->
        # 0 (the sine against the saw), decay 0.5 s -> an eighth note,
        # sustain 0.55 -> 0, filter decay 0.18 -> 0.06 s, its sustain 0.15
        # -> 0, resonance 0.25 -> 0.35, cutoff 160 Hz + 1400 Hz of envelope
        # -> 240 Hz opening 2.5 octaves.  `body: 0, decay: 1.n8, sustain: 0,
        # filter_decay: 0.06, filter_sustain: 0, resonance: 0.35, cutoff:
        # 240` is genre-fixes' bass.  Mono.
        def house_bass(source, cutoff: 200, env: 2.5, resonance: 0.3, body: 0.7, decay: 1.n8.dotted, sustain: 0.25,
                       filter_decay: 0.12, filter_sustain: 0.08, level: 1.0)
          MB::Sound.synth(source, voices: 1) { |v|
            fenv = v.env(0.001, filter_decay, filter_sustain, 0.04, gm: false)
            amp = v.env(0.002, decay, sustain, 0.04, gm: false) * (v.velocity * 0.4 + 0.6)
            saw = v.hz.saw.lp4(2 ** (fenv * env) * cutoff, resonance: resonance)
            tone = body == 0 ? saw : saw + v.hz.sine * body
            (tone * amp).softclip(0.7, 0.97)
          } * level
        end

        # A TB-303-style line (bin/synths/acid.rb's voice, compact): one
        # saw voice with slides (legato glides of +glide+ s) through the
        # diode ladder at +cutoff+ Hz (a number or a node such as a knob),
        # +reso+ resonance, the 303's envelope (Notes#acid_env) opening
        # +env_mod+ octaves, accents adding level and the accent sweep
        # (Notes#accent_sweep).  Mono.  (genre-fixes: techno's peak2 acid.)
        def acid(source, cutoff: 300, reso: 0.6, env_mod: 3.0, glide: 0.06, drive: 1.5, gain: 3.0)
          MB::Sound.synth(source, voices: 1) { |v|
            pitch = v.hz.glide(glide, legato: true)
            acc = v.accent
            meg = v.acid_env
            sweep = v.accent_sweep(meg, resonance: reso.respond_to?(:sample) ? 0.6 : reso)
            octaves = meg * (1 - acc * 0.5) * env_mod + sweep * (0.8 * 5.25)
            cut = ((2 ** octaves) * cutoff).clip(20, 16000)
            veg = v.env(0.002, 3.5, 0.0, 0.008, sensitivity: 1.0..1.0, curve: [0, 30, 0], gm: false).legato
            amp = veg * (acc * 0.36 + sweep * 0.112 + 0.55)
            (pitch.saw.diode(cut, resonance: reso, drive: drive) * amp * gain).filter(:highpass, cutoff: 35, quality: 0.7).softclip(0.6, 0.95)
          }
        end

        # A techno roller: a short sub sine (lowpassed at +cutoff+ Hz, one
        # voice) with a tick of filtered noise on every note (a bandpass
        # +tone+ times the note's frequency; +noise+ its level), and only
        # the part above 250 Hz (the tick and the sub's attack) in a small
        # room (+room+ wet), so the roll reads as a rhythm above the kick
        # instead of a second boom under it (patches-4, 2026-10-13;
        # maintainer on the techno stub: "Roller sub maybe needs filtered
        # noise and/or reverb, clashes with 808 kick").  Stereo.
        def roller(source, cutoff: 120, noise: 1.0, tone: 24, room: 0.35, level: 1.0)
          dry = MB::Sound.synth(source, voices: 1) { |v|
            sub = (v.hz.sine * v.env(0.002, 0.14, 0.5, 0.04, gm: false)).filter(:lowpass, cutoff: cutoff, quality: 0.7)
            tick = MB::Sound.noise.filter(:bandpass, cutoff: v.freq * tone, quality: 1.4) * v.env(0.001, 0.05, 0, 0.03, gm: false)
            sub + tick * noise
          } * level
          wet = dry.filter(:highpass, cutoff: 250, quality: 0.7).reverb(:room, dry: 0, wet: room, output_channels: 2)
          MB::Sound.stereo(dry, dry) + wet
        end

        # A detuned saw stab (the dnb_reese patch's voice: six detuned saws
        # through a four-pole lowpass at +cutoff+ Hz, a number or node such
        # as a knob, wobbled by a 2-bar LFO, highpassed at 150 Hz) with a
        # +drive+ knob (0..1) into its soft clipper: 1 is the Reese's own
        # drive (2.2x into softclip(0.35, 0.95)), the default 0.1 a gentle
        # edge (1.12x into softclip(0.845, 0.95)).  One voice, legato, like
        # the Reese.  The techno stub's stab (drums-3, 2026-10-13; the
        # maintainer on the Reese stab: "That's an insane amount of
        # distortion on the stab note. Could be useful in a different
        # context but not right here"); `drive: 1` brings the heavy one back.
        def stab(source, cutoff: 2400, drive: 0.1)
          gain = 1.0 + 1.2 * drive
          threshold = 0.9 - 0.55 * drive
          MB::Sound.synth(source, voices: 1) { |v|
            pitch = v.hz.glide(0.035, legato: true)
            saws = pitch.unison(6, detune: 0.32, spread: 0.5) { |p, _i| p.saw }
            lfo = 2 ** v.lfo(2.bars, shape: :sine, depth: 0.8)
            amp = v.env(0.004, 0.25, 0.85, 0.06, gm: false).legato
            ((saws.lp4(cutoff * lfo, resonance: 0.25) * gain).softclip(threshold, 0.95) * amp)
              .filter(:highpass, cutoff: 150, quality: 0.7).filter(:highpass, cutoff: 150, quality: 0.7)
          }
        end
      end

      # The patches as library entries (family :genre_patch; `L.inst.riser`,
      # find "weather"): [kind, tags, about] per method.
      PATCH_ENTRIES = {
        riser: [:instrument, %i[noise build], 'A noise riser: a resonant bandpass sweeping up over 4 bars, swelling'],
        breaks: [:instrument, %i[jungle drums chopped], 'A chopped break on a truncating sampler voice, through an S950-ish output stage'],
        rain: [:instrument, %i[weather texture stereo], 'Rain that ignores its notes: a wandering pink-noise bed, hiss, and drops'],
        wind: [:instrument, %i[weather texture stereo], 'Wind that ignores its notes: brown noise through a wandering bandpass, in gusts'],
        hiss: [:effect, %i[noise tape], 'Tape hiss that stops with the sound (a bus effect)'],
        house_bass: [:instrument, %i[bass house mono], 'A house bass: a saw through a four-pole with a tempo-set decay, a sine body'],
        acid: [:instrument, %i[bass techno mono], 'A TB-303-style line: slides, the diode ladder, accents'],
        roller: [:instrument, %i[bass techno stereo], 'A techno roller: a short sub with a noise tick, the top in a small room'],
        stab: [:instrument, %i[chord techno mono], 'A detuned saw stab (the Reese voice) with a drive knob'],
      }.freeze

      # The settings of the patches that become a track's knobs
      # (Arrangement::TrackKnobs; the maintainer, 2026-10-31: "Genre
      # patches now"): { patch => { setting => [range, unit, description] } },
      # the defaults the methods' own.  Only settings each patch reads as a
      # signal and whose knob plays the same samples as the number until
      # turned (measured: library-2's genre knob renders); left out: levels
      # and gains (the track's level is the fader), lengths and tween ends
      # (riser's bars, from, to: build-time), stab's drive (a softclip
      # threshold read as a number), and resonance, reso, and
      # filter_sustain, which read through a knob in float32 (-124 to -128
      # dB off until turned).
      PATCH_KNOBS = {
        breaks: { cutoff: [200.0..16000.0, 'Hz', 'Lowpass after the grit'], grit: [0.0..1.0, nil, 'Sample-rate reduction to 30 kHz, mixed in'] },
        rain: { density: [5.0..300.0, nil, 'Drops a second'] },
        house_bass: {
          cutoff: [40.0..2000.0, 'Hz', 'Four-pole cutoff before the envelope'], env: [0.0..6.0, 'oct', 'Filter envelope depth in octaves'],
          body: [0.0..2.0, nil, 'Sine body under the saw'], sustain: [0.0..1.0, nil, 'Level after the decay'],
          filter_decay: [0.01..2.0, 's', 'Filter envelope decay'],
        },
        acid: {
          cutoff: [40.0..4000.0, 'Hz', 'Diode ladder cutoff before the envelope'], env_mod: [0.0..6.0, 'oct', 'Envelope depth in octaves'],
          glide: [0.0..0.5, 's', 'Slide time'], drive: [0.0..4.0, nil, 'Ladder drive'],
        },
        roller: {
          cutoff: [40.0..400.0, 'Hz', 'Sub lowpass'], noise: [0.0..2.0, nil, 'Noise tick level'],
          tone: [4.0..64.0, nil, 'Tick bandpass, times the note'], room: [0.0..1.0, nil, 'Room on the part above 250 Hz'],
        },
        stab: { cutoff: [200.0..12000.0, 'Hz', 'Four-pole cutoff, wobbled by the LFO'] },
      }.freeze

      # The Params of patch +name+'s knob settings (PATCH_KNOBS), at the
      # method's defaults ({} for patches without).
      def self.patch_params(name)
        knobs = PATCH_KNOBS[name] or return {}
        defaults = patch_defaults(name)
        knobs.to_h { |k, (range, unit, about)|
          [k, MB::Sound::Param.declare(k, defaults.fetch(k).to_f, range: range, unit: unit, description: about)]
        }
      end

      # The number defaults of patch +name+'s keywords ({ keyword =>
      # number }), read from the method's definition with Prism (Ruby keeps
      # no default values to read back), once.
      def self.patch_defaults(name)
        @patch_defaults ||= {}
        @patch_defaults[name] ||= begin
          file, line = Patches.method(name).source_location
          tree = Prism.parse_file(file).value
          node = nil
          walk = ->(n) {
            next if node || n.nil?
            node = n if n.is_a?(Prism::DefNode) && n.name == name && n.location.start_line == line
            n.compact_child_nodes.each(&walk)
          }
          walk.(tree)
          (node&.parameters&.keywords || []).each_with_object({}) { |k, h|
            v = k.respond_to?(:value) ? k.value : nil
            h[k.name] = v.value if v.is_a?(Prism::IntegerNode) || v.is_a?(Prism::FloatNode)
          }.freeze
        end
      end

      Library.index.define_family(
        :genre_patch, kind: :instrument, owner: Patches, about: 'Patches genre templates use where no preset fits',
        apply: ->(name, source = nil, **kw) { Patches.public_send(name, source, **kw) },
        code: ->(e) { "Genre::Patches.#{e.name}(midi)" }
      )
      PATCH_ENTRIES.each do |name, (kind, tags, about)|
        file, line = Patches.method(name).source_location
        Library.index.register(Library::Entry.new(
          name: name, kind: kind, family: :genre_patch, tags: tags, about: about, params: -> { Genre.patch_params(name) },
          location: "#{file.delete_prefix(File.expand_path('../../..', __dir__) + '/')}:#{line}",
          builder: ->(source = nil, **kw) { Patches.public_send(name, source, **kw) }
        ))
      end
    end
  end
end
