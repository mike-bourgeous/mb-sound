module MB
  module Sound
    # Drum machine kits for the console and scripts (see MB::Sound::Drums).
    # Included in MB::Sound.
    module DrumMethods
      # A TR-808-flavored drum kit (a Drums::Kit node) played by +source+: a
      # grid Kit (rows play the voices they name), or any MIDI source (a
      # clip, `midi`, a MIDI file, a Stream; GM drum notes are routed to the
      # voices).  Per-voice knobs go in Hashes by voice name; see
      # Drums::TR808.kit and Drums::TR808 for every voice and knob.
      # +outputs: :separate+ gives one named channel per voice instead of
      # the mix (see Drums::TR808.kit).
      #
      # Voices: kick, snare, rimshot, clap, closed_hat (hat), open_hat,
      # cymbal, cowbell, low/mid/high_tom, low/mid/high_conga, claves,
      # maracas.  Knobs: tune (Hz), decay (s), tone (0..1), snappy (0..1,
      # snare and toms), level, and sigh (kick).  In grids, X is an
      # accent (+:accent+ louder than x, 6.db by default); MIDI files and
      # live MIDI play velocity 127 +:accent+ louder than 64 (about linear
      # velocity at 6.db; see Drums.accented).
      #
      # Examples (bin/sound.rb):
      #     bg :drums, tr808(grid(16, kick: 'X..x..x...x.x...', snare: '....X.......X...', hat: 'x.xXx.x.x.xXx.x.').loop)
      #     bg :drums, tr808(grid(16, kick: 'x...x...', cowbell: '..x.xX.x').loop, kick: { tune: 45, decay: 1.2 }, more_cowbell: true)
      #     bg :pads, tr808(midi)                       # play the kit from a MIDI drum pad (GM notes)
      #     bg :file, tr808('drums.mid')               # or a drum track
      #     play tr808(grid(16, kick: 'x...').loop, kick: { tune: 4.bars.lfo.at(45..60) })   # moving knobs
      #     outs = tr808(grid(16, kick: 'x...x...', snare: '....x...').loop, outputs: :separate)
      #     bg :drums, outs[:kick].softclip(0.5) + outs[:snare].reverb(:room)   # individual outputs
      def tr808(source, **settings)
        Drums::TR808.kit(source, **settings)
      end

      # A TR-909-flavored drum kit (a Drums::Kit node) played by +source+,
      # like #tr808: analog kick, snare, toms, rimshot, and clap, and 6-bit
      # sampled hats, crash, and ride (see Drums::TR909 for voices and
      # knobs, Drums::Machine#kit for options).  +shuffle:+ (0..6) swings
      # grids and clips like the 909's shuffle; flam-marked notes ('f' or
      # 'F' in a grid, `D1.flam` in a seq) play as flams, +flam:+ apart (16
      # ms by default; tr808 kits play them too).
      #
      # Voices: kick, snare, rimshot, clap, low/mid/high_tom, closed_hat
      # (hat), open_hat, crash, ride.
      #
      # Examples (bin/sound.rb):
      #     bg :house, tr909(grid(16, kick: 'X...x...x...x...', clap: '....X.......X...', hat: '..x...x...x...x.', oh: '..x...x...x...X.').loop, shuffle: 2)
      #     bg :techno, tr909(grid(16, kick: 'X...X...X...X...', hat: 'xxXxxxXxxxXxxxXx', ride: 'x.x.x.x.x.x.x.x.').loop, kick: { decay: 0.9, attack: 0.8 })
      #     bg :roll, tr909(grid(16, snare: 'x.x.x.xfxxxxXXFX').loop, flam: 12.ms)
      def tr909(source, **settings)
        Drums::TR909.kit(source, **settings)
      end

      # Builds a drum machine of your own (a Drums::Machine) from the block:
      # `voice :name, knob: default do |h| ... end` for each voice (layers
      # from the Drums::Hit +h+: body, noise, click, metal, sample, fm, env,
      # sweep, bursts), `choke :open_hat, by: :closed_hat` for chokes.  With
      # a +source+, returns the kit playing it (see Drums::Machine#kit for
      # the options: knobs per voice, accent:, shuffle:, flam:, outputs:,
      # ...); without, the machine, to play later with `machine.kit(source)`
      # (or `machine.(source)`).  A block without parameters runs on the
      # builder (`voice ...`); with one, call it on that (`k.voice ...`).
      #
      # Examples (bin/sound.rb):
      #     bg :zap, kit(grid(16, kick: 'X...x...x...x..x', snare: '....X.......X...').loop) {
      #       voice(:kick, tune: 45) { |h| h.body(h.tune, decay: 0.5, sweep: 4).softclip(0.6) + h.click(0.3) }
      #       voice(:snare) { |h| h.fm(330, ratio: 2.3, index: 2, decay: 0.15) * 0.4 + h.noise(decay: 0.2, highpass: 2000) * 0.5 }
      #     }
      #     perc = kit { voice(:hat, decay: 0.04) { |h| h.metal.filter(:highpass, cutoff: 8000) * h.env(h.decay) * 3 } }
      #     bg :hats, perc.kit(grid(16, hat: 'x.xX' * 4).loop, shuffle: 3)
      def kit(source = nil, name: :kit, **settings, &block)
        raise ArgumentError, 'kit needs a block defining its voices' unless block
        machine = Drums::Machine.new(name, &block)
        return machine if source.nil?
        machine.kit(source, **settings)
      end
      alias drum_kit kit
    end

    # The drum machines as library entries (family :machine, `L.kit.tr909`).
    Library.index.define_family(:machine, kind: :kit, owner: DrumMethods, about: 'Drum machines: tr808(grid), tr909(midi)',
                                apply: ->(name, source = nil, **kw) { MB::Sound.public_send(name, source, **kw) },
                                code: ->(e) { "#{e.name}(grid(16, kick: 'x...x...').loop)" })
    {
      tr808: [%i[analog classic], 'A TR-808-flavored kit: resonator, metal-bank, and noise voices'],
      tr909: [%i[analog classic rom], 'A TR-909-flavored kit: analog kick/snare/toms/clap, 6-bit ROM hats and cymbals'],
    }.each do |name, (tags, about)|
      Library.index.register(Library::Entry.new(
        name: name, kind: :kit, family: :machine, tags: tags, about: about, location: "lib/mb/sound/drum_methods.rb:#{DrumMethods.instance_method(name).source_location[1]}",
        builder: ->(source = nil, **kw) { MB::Sound.public_send(name, source, **kw) }
      ))
    end
  end
end
