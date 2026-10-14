module MB
  module Sound
    module Drums
      # TR-909-flavored drums, built with the kit builder (Drums::Machine;
      # every voice is a block of Drums::Hit layers, so it doubles as an
      # example): analog-style kick (a pinged sine with a fast pitch sweep,
      # driven, plus a beater click), snare (two swept heads plus noise),
      # three toms, rimshot, and a clap of four bursts and a tail; hats,
      # crash, and ride are 6-bit samples (ROM) synthesized from square
      # banks, ring modulation, and noise the first time they are played
      # (no recorded cymbals), played by a sampler like the 909's.
      # Playable and inspired by the 909, not an emulation.
      #
      # Knobs (numbers, Lengths, or nodes):
      # - kick: tune (Hz), decay (s to -60 dB), attack (click, 0..1), punch
      #   (pitch sweep, 0..1), drive (0..1)
      # - snare: tune (Hz), tone (noise brightness, 0..1), snappy (noise,
      #   0..1), decay
      # - toms: tune (Hz), decay; rimshot: tune, decay; clap: tone, decay
      # - hats: decay (closed, open), tune (semitones); crash, ride: tune
      #   (semitones), decay (nil: the sample's own)
      # - every voice: level, accent (dB), velocity_curve, flam (see
      #   Machine#kit)
      #
      # The kit takes +shuffle:+ (0..6, the 909's shuffle steps) and
      # +flam:+, the spacing of flam-marked notes (`D1.flam`, 'f' in a grid;
      # see Machine#kit).  The closed hat chokes the open hat.
      #
      #     tr909(grid(16, kick: 'X...x...x...x...', clap: '....X.......X...', hat: 'x.xxx.xxx.xxx.xx', oh: '..X...X...X...X.').loop, shuffle: 2)
      module TR909
        # ROM sample rate (Hz) and bits (the 909's cymbals were 6-bit).
        ROM_RATE = 32_000
        ROM_BITS = 6

        # The seed of the ROM's noise (the same cymbals every time).
        ROM_SEED = 0x909

        # Square banks of the ROM's metal (Hz): two sets of six, ring
        # modulated.
        METAL_A = [463.0, 727.0, 891.0, 1103.0, 1381.0, 1607.0].freeze
        METAL_B = [2953.0, 3517.0, 4211.0].freeze

        # How each ROM sample is made: seconds long, seconds to fall 60 dB
        # (a fast and a slow part, with the share of the fast), the
        # highpass cutoff, the noise share, and bell partials (ride).
        ROM = {
          closed_hat: { length: 0.25, fast: 0.05, slow: 0.22, fast_share: 0.6, highpass: 7000, noise: 0.45, bell: nil },
          open_hat: { length: 1.2, fast: 0.15, slow: 1.15, fast_share: 0.35, highpass: 6500, noise: 0.45, bell: nil },
          crash: { length: 2.4, fast: 0.3, slow: 2.3, fast_share: 0.3, highpass: 3800, noise: 0.6, attack: 0.004, bell: nil },
          ride: { length: 2.8, fast: 0.2, slow: 2.7, fast_share: 0.25, highpass: 4800, noise: 0.3,
                  bell: [[2793.0, 1.0], [4167.0, 0.6], [5381.0, 0.45], [7243.0, 0.3]], bell_decay: 1.6, bell_share: 0.35 },
        }.freeze

        @rom = {}
        @rom_lock = Mutex.new

        # General MIDI notes per voice.
        GM_MAP = {
          kick: [35, 36], rimshot: [37], snare: [38, 40], clap: [39], closed_hat: [42, 44], open_hat: [46],
          low_tom: [41, 43, 45], mid_tom: [47, 48], high_tom: [50], crash: [49, 52, 55, 57], ride: [51, 53, 59],
        }.freeze

        module_function

        # The ROM sample +name+ (a key of ROM) as a MB::Sound::Sample: 6-bit
        # audio at 32 kHz (played at 48 kHz), made once per process.
        def rom(name)
          spec = ROM.fetch(name) { raise ArgumentError, "No TR-909 ROM sample #{name.inspect} (#{ROM.keys.join(', ')})" }
          @rom_lock.synchronize { @rom[name] ||= make_rom(name, spec) }
        end

        # Synthesizes one ROM sample (see ROM): the product of two square
        # banks (dense, inharmonic metal) mixed with noise, highpassed, under
        # a two-part decay, then through a 32 kHz converter (Sample::Lofi)
        # at 6 bits of full scale.
        def make_rom(name, spec)
          fs = 48000.0
          n = (spec[:length] * fs).round
          t = Numo::DFloat.new(n).seq / fs

          squares = ->(freqs) {
            freqs.each_with_index.sum { |f, i| (Numo::NMath.sin(t * (2 * Math::PI * f) + i * 0.7) + 1e-9).sign } / freqs.length
          }
          metal = squares.(METAL_A) * squares.(METAL_B)
          noise = MB::Sound.with_seed(ROM_SEED + ROM.keys.index(name)) { Numo::DFloat.cast(MB::Sound.noise.sample(n)) }
          x = metal * (1 - spec[:noise]) + noise * spec[:noise]
          2.times do
            f = MB::Sound::Filter::Cookbook.new(:highpass, fs, spec[:highpass], quality: Math.sqrt(0.5))
            x = Numo::DFloat.cast(f.process(x))
          end

          fast = Numo::NMath.exp(t * (Math.log(1e-3) / spec[:fast]))
          slow = Numo::NMath.exp(t * (Math.log(1e-3) / spec[:slow]))
          env = fast * spec[:fast_share] + slow * (1 - spec[:fast_share])
          if spec[:attack]
            a = (spec[:attack] * fs).round
            env[0...a] = env[0...a] * (Numo::DFloat.new(a).seq / a)
          end
          x *= env

          if spec[:bell]
            bell_env = Numo::NMath.exp(t * (Math.log(1e-3) / spec[:bell_decay]))
            bell = spec[:bell].sum { |f, g| Numo::NMath.sin(t * (2 * Math::PI * f)) * g } * bell_env
            x = x / x.abs.max * (1 - spec[:bell_share]) + bell / bell.abs.max * spec[:bell_share]
          end

          # Fade the end so the cut is silent
          fade = (0.01 * fs).round
          x[(n - fade)..] = x[(n - fade)..] * (1 - Numo::DFloat.new(fade).seq / fade)
          x = x / x.abs.max

          # The converter (hold at 32 kHz), then full scale at 6 bits
          x = Numo::DFloat.cast(MB::Sound::Sample::Lofi.process(x, sample_rate: fs, rate: ROM_RATE))
          x = MB::Sound::Sample::Lofi.bits(x / x.abs.max, ROM_BITS)
          MB::Sound::Sample.new(Numo::SFloat.cast(x), name: "tr909 #{name}")
        end

        # The TR-909 design (a Drums::Machine); see the module description.
        def machine
          @machine ||= Drums.machine(:tr909) do
            voice :kick, tune: 50.0, decay: 0.55, attack: 0.8, punch: 0.9, drive: 0.8, gm: GM_MAP[:kick], as: [:bd, :bass_drum] do |h|
              body = h.body(h.tune, decay: h.decay, sweep: h.punch * 5, sweep_time: 0.018, drop: 0.25, drop_time: 0.15)
              drive = Drums.exp2(h.drive * 2)
              punch = (body * drive).softclip(0.6, 1.0) * (1.25 / (1 + 0.25 * drive))
              tick = Drums.scale(h.noise(decay: 0.006, highpass: 1500, lowpass: 7000), h.attack * 0.9)
              h.mix(punch, h.click(h.attack * 0.9, tone: 0.75), tick)
            end

            voice :rimshot, tune: 480.0, decay: 0.035, gm: GM_MAP[:rimshot], as: [:rim, :rs, :side_stick], level: 0.9 do |h|
              f = h.hz(h.tune)
              pings = h.mix(h.body(f, decay: h.decay) * 0.9, h.body(f * 3.4, decay: h.decay * 0.6) * 0.6, h.body(f * 0.46, decay: h.decay * 1.5) * 0.4)
              pings.filter(:highpass, cutoff: 350, quality: 0.7).softclip(0.7, 1.0)
            end

            voice :snare, tune: 185.0, tone: 0.5, snappy: 0.6, decay: 0.2, gm: GM_MAP[:snare], as: [:sd], level: 0.95 do |h|
              f = h.hz(h.tune)
              heads = h.body(f, decay: h.decay, sweep: 0.6, sweep_time: 0.012) * 0.6 + h.body(f * 1.62, decay: h.decay * 0.6, sweep: 0.6, sweep_time: 0.012) * 0.4
              noise = h.noise(decay: h.snappy * 0.2 + 0.08, highpass: 1000, lowpass: Drums.exp2(h.tone * 2) * 3500)
              h.mix(heads * 0.55, Drums.scale(noise, h.snappy * 1.3))
            end

            voice :clap, tone: 0.5, decay: 0.28, gm: GM_MAP[:clap], as: [:cp, :hc, :hand_clap], level: 0.75 do |h|
              bursts = h.bursts(4, 0.0085, falloff: 0.85)
              burst_env = Drums.decay_env(bursts, 0.009, curve: 30)
              tail_env = Drums.decay_env(Repeats.new(h.t, [[0.0255, 1.0]]), h.decay)
              noise = MB::Sound.noise.filter(:bandpass, cutoff: Drums.exp2(h.tone - 0.5) * 1150, quality: 1.3).filter(:highpass, cutoff: 500, quality: 0.7)
              noise * (burst_env + tail_env * 0.45) * 4.4
            end

            {
              low_tom: [95.0, 0.55, [:lt]], mid_tom: [135.0, 0.5, [:mt, :tom]], high_tom: [190.0, 0.45, [:ht]],
            }.each do |name, (tune, decay, aliases)|
              # The round 1 toms (drums-3: the maintainer on the rounder
              # round 2 toms, "the round 1 toms are fine, I just like the 808
              # toms a lot"): a quick strike and a short drop, with a breath
              # of noise
              voice name, tune: tune, decay: decay, gm: GM_MAP[name], as: aliases, level: 0.75 do |h|
                f = h.hz(h.tune)
                body = h.body(f, decay: h.decay, sweep: 0.9, sweep_time: 0.01, drop: 0.4, drop_time: 0.25)
                h.mix(body, h.noise(decay: 0.05, bandpass: f * 5, quality: 1.0) * 0.12)
              end
            end

            voice :closed_hat, decay: 0.06, tune: -3, gm: GM_MAP[:closed_hat], as: [:hat, :hh, :ch], level: 0.45 do |h|
              h.sample(TR909.rom(:closed_hat), tune: h.tune, decay: h.decay, curve: 40)
            end

            voice :open_hat, decay: 0.3, tune: -3, gm: GM_MAP[:open_hat], as: [:oh], level: 0.45 do |h|
              h.sample(TR909.rom(:open_hat), tune: h.tune, decay: h.decay, curve: 40)
            end

            voice :crash, tune: 0, decay: nil, gm: GM_MAP[:crash], as: [:cr, :cy, :cymbal], level: 0.4 do |h|
              h.sample(TR909.rom(:crash), tune: h.tune, decay: h.decay)
            end

            voice :ride, tune: 0, decay: nil, gm: GM_MAP[:ride], as: [:rd], level: 0.45 do |h|
              h.sample(TR909.rom(:ride), tune: h.tune, decay: h.decay)
            end

            choke :open_hat, by: :closed_hat
          end
        end

        # A Drums::Kit of 909 voices played by +source+ (see Machine#kit for
        # every option, and the module description for knobs).
        def kit(source, **options)
          machine.kit(source, **options)
        end
      end
    end
  end
end
