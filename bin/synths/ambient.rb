#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Ambient instruments (singing bowls, gong, koto-ish FM plucks, harp, sine
# drones, a rain stick, worn tape, soft rooms), playable from MIDI.
#
# Where they came from: the persona panel experiment of 2026-10-13
# (research branch research-persona-zen, research/persona-panel/zen/), in
# which a fictional persona, Kaede Rowntree (a piano tuner turned field
# recordist making zen ambient soundscapes), wrote the song "Tin Roof, Slow
# River" (bin/songs/tin_roof.rb) with the public API.  The instruments moved
# here so they can be played, reused, and saved as presets, named for the
# genre (patches-2, 2026-10-13).  The weather (rain, river) stays in the
# song.
#
# Patches (-p):
#   bowl      a singing bowl struck at each note-on (velocity is the
#             force): four partials at bowl-like inharmonic ratios, each a
#             doublet beating (--beat Hz apart), higher ones dying sooner,
#             in a long soft room (--space)
#   rin       a small high bowl: faster beating, a shorter room
#   gong      a tam-tam: dense low partials gliding down after the stroke
#             and a high shimmer swelling in over seconds, ringing at 16
#             high partials spread in stereo (ring:, partials:, spread:)
#             (D2 plays 55 Hz; other notes transpose it)
#   koto      a plucked FM tone (1:1 body, faint 7:1 tine; more a koto or
#             a hammered string than an e-piano) through worn tape
#             (--wear) and a room
#   harp      Karplus-Strong plucks (bin/synths/pluck.rb), soft, through the
#             tape and a room
#   drone     two old sine generators per side (root, fifth, octave)
#             drifting fractions of a hertz, beating
#   rainstick a rain stick tipped over for each note: clicks swelling and
#             fading over the note, moving right to left
#
# Every patch is one method taking a MIDI source (Notes, Clip, MIDI file, or
# Stream) and its knobs as keywords: ambient_bowl_voice(midi, space:),
# ambient_rin_voice, ambient_gong_voice, ambient_koto_voice(midi, wear:, space:),
# ambient_harp_voice, ambient_drone_voice, ambient_rainstick_voice; the effects
# ambient_tape(sig, wear:) and ambient_room(sig, space:) stand alone too.  Each
# is also a preset (presets/ambient_*.mbg.rb): `preset :ambient_bowl, midi: midi`,
# `preset :ambient_tape, input: mic, wear: 0.7`.
#
# Usage:
#     bin/synths/ambient.rb                           # live MIDI, the bowls
#     bin/synths/ambient.rb -p gong song.mid gong.flac
#     bin/synths/ambient.rb -p koto -w 0.8 song.mid worn.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/ambient.rb'`):
#     bpm 60
#     bg :bowls, ambient_bowl_voice(seq(D3.n1, A3.n1, R.n1, G3.n2, B3.n2).loop)
#     bg :drone, ambient_drone_voice(seq(D2.n1).loop) * 1.5
#     bg :keys, ambient_koto_voice(seq(A4, R, R, D5, R, B4, R, R).n8.humanize(1.n64).loop, wear: 0.4)
#     play 440.hz.square.then { |s| ambient_tape(s * 0.1, wear: 0.9) }   # the tape alone

require 'bundler/setup'
require 'mb-sound'
require_relative 'pluck'

module MB::Sound
  # A dust generator: sparse single-sample impulses with random heights
  # (0..1), about +rate+ per second, from uniform noise above a threshold.
  def self.ambient_dust(rate)
    p = rate / 48000.0
    (noise.aabs - (1 - p)).aclip(0, nil) * (1 / p)
  end

  # A slow random walk between +lo+ and +hi+: a new random target +rate+
  # times a second, glided over one step.
  def self.ambient_walk(rate, lo, hi)
    rate.hz.lfo.square.sample_hold.smooth(1.0 / rate).at(lo..hi)
  end

  # A singing bowl struck by +strike+ (impulses; their heights are the
  # force) at +freq+ (Hz, a number or a node): four partials at bowl-like
  # inharmonic ratios, each a doublet a little apart (+beat+ Hz for the
  # first, wider above: beating), higher partials dying sooner (+decay+
  # seconds for the first).  +flat+ in cents.
  def self.ambient_bowl(strike, freq, flat: 0, decay: 24, beat: 0.7)
    freq *= 2 ** (-flat / 1200.0)
    [[1.0, 1.0, 1.0], [2.77, 0.45, 0.46], [5.15, 0.22, 0.25], [8.1, 0.1, 0.15]].map.with_index { |(r, amp, dec), i|
      b = beat * (i + 1) ** 1.3
      strike.ping(freq * r, decay: decay * dec) * amp + strike.ping(freq * r + b, decay: decay * dec * 0.8) * (amp * 0.7)
    }.reduce(:+)
  end

  # Dry stereo +sig+ plus a reverb of it scaled by +space+ (a number or a
  # node): the reverb is wet-only, so a knob can scale it.  The dry part
  # waits in silence for the reverb's tail (a sum ends when any of its
  # inputs ends).
  def self.ambient_room(sig, space: 0.5, decay: 8, room_size: 0.9)
    wet = sig.reverb(room_size: room_size, decay: decay, damping: 0.55, predelay: 0.03, dry: 0, wet: 1)
    sig.and_then(silence(decay * 2)) + wet * space
  end

  # Tape wear (+wear+ 0..1, a number or a node): wow (a slowly wandering
  # delay), a lowpass that falls, and sample-rate crush that grows with
  # wear.
  def self.ambient_tape(sig, wear: 0)
    wow = sig.delay(0.37.hz.lfo.sine.at(0.006..0.009) + ambient_walk(1.3, -0.0007, 0.0007))
    dark = wow.filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6)
    dark.decimate(16000 - wear * 11000, mix: wear * 0.6)
  end

  # Singing bowls struck at each note-on (velocity is the force), panned
  # at +pan+, in a long soft room (+space+, +room+ seconds of decay).
  def self.ambient_bowl_voice(midi, flat: 0, decay: 24, beat: 0.7, level: 0.12, pan: 0, space: 0.5, room: 9, voices: 6)
    bowls = synth(midi, voices: voices) { |v| ambient_bowl(v.trigger, v.freq, flat: flat, decay: decay, beat: beat) }
    ambient_room((bowls * level).pan(pan), space: space, decay: room)
  end

  # A small rin (high bowl): faster beating, a shorter room.
  def self.ambient_rin_voice(midi, flat: 0, decay: 24, beat: 1.6, level: 0.08, pan: 0.15, space: 0.5, room: 7, voices: 4)
    ambient_bowl_voice(midi, flat: flat, decay: decay, beat: beat, level: level, pan: pan, space: space, room: room, voices: voices)
  end

  # A tam-tam: dense low inharmonic partials (from +freq+ Hz at D2,
  # following the note) gliding down a little after the stroke (a
  # flat-centered gong), and a high shimmer swelling in over a couple of
  # seconds (energy cascading up), then fading; in a big room.  The
  # shimmer is a wandering band of noise, +ring+ (0..1, power share) of
  # it ringing through resonators at +partials+ high partials of the gong
  # (AMBIENT_GONG_SHIMMER: 30-125 times its pitch, gliding with it, each a
  # little apart in how far it glides; +ring_decay+ seconds at 60 times
  # the pitch, shorter above, longer below), every other partial panned
  # to the other side by +spread+ (0 mono, 1 hard left and right), so the
  # shimmer sparkles across the stereo field.
  #
  # patches-2 (2026-10-13: "a little more tonality and resonance in the
  # shimmer would be good") added seven partials 44-90 times the pitch, in
  # mono (`partials: 7, spread: 0` is close to it; ring: 0 is the earlier
  # noise-only shimmer); patches-3 (2026-10-13: "Having more shimmer
  # partials to spread around would be even better") has 16, wider.
  def self.ambient_gong_voice(midi, freq: 55.0, glide: 0.05, shimmer: 0.07, ring: 0.6, ring_decay: 0.8, partials: 16, spread: 0.7, space: 0.5)
    gong = synth(midi, voices: 1) { |n|
      hit = n.trigger
      fall = adsr(0, 4, 0, 0, trigger: hit, curve: :linear)
      f = freq * 2 ** ((n.number - D2.number) / 12.0)
      ratios = [1.0, 1.47, 2.02, 2.51, 2.97, 3.58, 4.23, 5.06, 5.91, 6.8]
      low = ratios.map.with_index { |r, i|
        hit.ping(f * r * (1 + fall * glide), decay: 24.0 / (1 + i * 0.35)) * (0.6 / (1 + i * 0.25))
      }.reduce(:+)
      swell = n.env(2.2, 7, 0, 3, curve: :swell, gm: false)
      band = noise.filter(:bandpass, cutoff: ambient_walk(0.7, 2400, 5200), quality: 1.5)
      air = band * swell * shimmer
      if ring > 0
        sides = ambient_gong_shimmer(partials).each_with_index.group_by { |_r, i| i % 2 }.values.map { |rs|
          rs.map { |(r, g), _i|
            band.ping(f * r * (1 + fall * glide * g), decay: ring_decay * (60.0 / r)**0.5)
          }.reduce(:+)
        }
        # (each side's resonator sum is about 51 sqrt(partials) times the band's RMS at 0.8 s, RMS growing about
        # as decay ** 0.6; AMBIENT_GONG_RING keeps patches-2's tonal level, about 0.8 sqrt(ring) times the band,
        # in each channel at any spread)
        k = Math.sqrt(ring) / (AMBIENT_GONG_RING * Math.sqrt(partials)) * (0.8 / ring_decay)**0.6
        l, r = sides.length == 2 ? sides : [sides[0], sides[0] * 0]
        a = (1 + spread) / 2.0
        b = (1 - spread) / 2.0
        noise_part = (band * Math.sqrt(1 - ring) * swell * shimmer).pan(0.2)
        air = noise_part + stereo(l * a + r * b, l * b + r * a) * (swell * shimmer * (k / Math.sqrt(a * a + b * b)))
      else
        air = air.pan(0.2)
      end
      low = low.filter(:highpass, cutoff: 38, quality: 0.6) * 0.12
      stereo(low, low) + air
    }
    ambient_room(gong, space: space, decay: 10, room_size: 1.0)
  end

  # Calibration of ambient_gong_voice's shimmer resonators (see there).
  AMBIENT_GONG_RING = 63.0

  # The shimmer partials of ambient_gong_voice: +count+ [ratio, glide]
  # pairs, ratios spread geometrically over 30..125 times the gong's pitch
  # with a fixed irregular nudge (so they never line up as harmonics), and
  # each partial's share (0.6..1.4) of the gong's downward glide.
  def self.ambient_gong_shimmer(count)
    return [] if count < 1
    (0...count).map { |i|
      t = count == 1 ? 0.5 : i / (count - 1.0)
      nudge = ((i * 0.618034) % 1 - 0.5) * 0.06
      [30.0 * (125 / 30.0)**t * (1 + nudge), 0.6 + 0.8 * ((i * 0.381966) % 1)]
    }
  end

  # A plucked FM tone for a kankyō motif (written as a soft e-piano; it
  # sounds more like a koto or a hammered string): a sine carrier, a 1:1
  # modulator whose index falls (the body), and a faint 7:1 tine; through
  # worn tape (+wear+) and a small room (+space+).
  def self.ambient_koto_voice(midi, wear: 0, space: 0.5, level: 0.11, pan: -0.15)
    keys = synth(midi, voices: 4) { |v|
      body = v.hz.transpose(0).sine.at(0.9) * v.env(0.002, 1.8, 0.15, 1.5, gm: false)
      tine = v.hz.transpose(12 * Math.log2(7)).sine.at(0.25) * v.env(0.001, 0.25, 0, 0.2, gm: false)
      v.hz.pm(body + tine) * v.env(0.004, 3.2, 0.0, 1.6, gm: false) * (v.velocity * 0.5 + 0.5)
    }
    ambient_room(ambient_tape(keys * level, wear: wear).pan(pan), space: space, decay: 6, room_size: 0.7)
  end

  # The harp: soft Karplus-Strong plucks (MB::Sound.pluck_voice), through
  # worn tape (+wear+) and a small room (+space+).
  def self.ambient_harp_voice(midi, wear: 0, space: 0.5, level: 0.14, pan: 0.3, sustain: 2.5, brightness: 5)
    harp = synth(midi, voices: 3) { |v| pluck_voice(v, sustain: sustain, brightness: brightness) }
    ambient_room(ambient_tape(harp * level, wear: wear).pan(pan), space: space, decay: 5, room_size: 0.6)
  end

  # Two old sine generators per side on +root+ (Hz, a number or a node):
  # the root, a fifth (+0.31 Hz), and an octave, each drifting by a slow
  # random walk (a fraction of a hertz) and beating against the others; a
  # little warmth, a 900 Hz lowpass.  Stereo.
  def self.ambient_drone(root, level: 1.0)
    side = ->(spread) {
      gen = ->(f, depth) { (f + ambient_walk(0.05, -depth, depth)).tone.sine }
      sig = gen.(root * 1.0, 0.15 + spread) * 0.5 + gen.(root * 2 ** (7 / 12.0) + 0.31, 0.2) * 0.3 + gen.(root * 2.0 - (0.17 + spread), 0.25) * 0.18
      sig.softclip(0.8, 0.95).filter(:lowpass, cutoff: 900, quality: 0.6)
    }
    stereo(side.(0.0), side.(0.05)) * level * 0.18
  end

  # The drone played from MIDI: .ambient_drone on each note, swelling in
  # over +attack+ seconds and out over +release+.
  def self.ambient_drone_voice(midi, level: 1.0, attack: 3.0, release: 4.0, voices: 3)
    synth(midi, voices: voices) { |v|
      ambient_drone(v.freq, level: level) * v.env(attack, 0, 1, release, curve: :gentle, gm: false)
    }
  end

  # A rain stick tipped over for each note: clicks whose density follows
  # a slow swell over +tip+ seconds, bright pings at random pitches,
  # moving right to left across the field over +across+ seconds.
  def self.ambient_rainstick_voice(midi, tip: 2.8, across: 9, level: 1.6)
    stick = synth(midi, voices: 1) { |n|
      swell = n.env(tip, 5, 0, 1.5, curve: :gentle, gm: false)
      clicks = ambient_dust(700)
      pitch = noise.sample_hold(clicks) * 1800 + 4200
      where = adsr(0, across, 0, 0, trigger: n.trigger, curve: :linear) * 1.4 - 0.7 # right to left
      (clicks.ping(pitch, decay: 0.012) * 0.25 * swell).pan(where)
    }
    stick * level
  end

  # The script's instruments by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  def self.ambient_patch(midi, patch = :bowl, space: 0.5, wear: 0.0)
    case patch
    when :bowl then ambient_bowl_voice(midi, space: space.constant.named('space'))
    when :rin then ambient_rin_voice(midi, space: space.constant.named('space'))
    when :gong then ambient_gong_voice(midi, space: space.constant.named('space'))
    when :koto then ambient_koto_voice(midi, wear: wear.constant.named('wear'), space: space.constant.named('space'))
    when :harp then ambient_harp_voice(midi, wear: wear.constant.named('wear'), space: space.constant.named('space'))
    when :drone then ambient_drone_voice(midi)
    when :rainstick then ambient_rainstick_voice(midi)
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  # Where the patches came from, for preset descriptions (--save writes
  # it into the document): +what+ is the patch (a Symbol) or a phrase.
  def self.ambient_description(what)
    what = "Ambient patch :#{what}" if what.is_a?(Symbol)
    "#{what} from bin/synths/ambient.rb, " \
      'first made by Kaede Rowntree, a fictional piano tuner turned field recordist, ' \
      'for the soundscape "Tin Roof, Slow River" (bin/songs/tin_roof.rb) ' \
      'in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).'
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { ambient_description(p.patch) },
      patch: [:bowl, Symbol, '-p', 'Instrument to play', [:bowl, :rin, :gong, :koto, :harp, :drone, :rainstick]],
      space: [0.5, Float, '-s', 'Room level 0..1 (bowls, rin, gong, koto, harp)', 0.0..1.0],
      wear: [0.0, Float, '-w', 'Tape wear 0..1 (koto, harp)', 0.0..1.0],
    ) { |midi, p|
      ambient_patch(midi, p.patch, space: p.space, wear: p.wear)
    }
  end
end
