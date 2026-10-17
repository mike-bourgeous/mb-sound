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
#             high partials spread in stereo (ring:, partials:, spread:;
#             --tune moves the shimmer up or down in semitones, -7 by
#             default; --spread sets its width, 0 mono to 1 wide, 0.7 by
#             default)
#             (D2 plays 55 Hz; other notes transpose it)
#   koto      a plucked FM tone (1:1 body, faint 7:1 tine; more a koto or
#             a hammered string than an e-piano) in a room, recorded on
#             worn tape (--wear, 0.6 by default: 10 bits of hiss)
#   harp      Karplus-Strong plucks (bin/synths/pluck.rb), soft, in a room
#             on the same tape
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
#     bin/synths/ambient.rb -p gong --tune 0 song.mid bright_shimmer.flac   # patches-4's shimmer (-7 since patches-5)
#     bin/synths/ambient.rb -p gong --spread 1 song.mid wide_shimmer.flac
#     bin/synths/ambient.rb -p koto -w 0.8 song.mid worn.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/ambient.rb'`):
#     bpm 60
#     bg :bowls, ambient_bowl_voice(seq(D3.n1, A3.n1, R.n1, G3.n2, B3.n2).loop)
#     bg :drone, ambient_drone_voice(seq(D2.n1).loop) * 1.5
#     bg :keys, ambient_koto_voice(seq(A4, R, R, D5, R, B4, R, R).n8.humanize(1.n64).loop, wear: 0.4)
#     play 440.hz.square.then { |s| ambient_tape(s * 0.1, wear: 0.9) }   # the tape alone
#     knob :spread, 0.7, range: 0..1; bg :gong, ambient_gong_voice(seq(D2.n1, R.n1, R.n1).loop, spread: knob(:spread))
#     turn :spread, 1, over: 2      # widen the gong's shimmer while it rings (0 for mono)

require 'bundler/setup'
require 'mb-sound'
require_relative 'pluck'

module MB::Sound
  # A dust generator: sparse single-sample impulses with random heights
  # (0..1), about +rate+ per second, from uniform noise above a threshold.
  # (The persona's hand-made dust; the rain stick uses the library's
  # dust() since textures-2, 2026-10-15; bin/songs/tin_roof.rb still uses
  # this one.)
  def self.ambient_dust(rate)
    p = rate / 48000.0
    (noise.aabs - (1 - p)).aclip(0, nil) * (1 / p)
  end

  # A slow random walk between +lo+ and +hi+: a new random target +rate+
  # times a second, glided over one step (a smoothstep), starting from the
  # middle.  (The persona's hand-made walk; the tape and the drone use
  # .ambient_drift since textures-2; the gong's shimmer band and
  # bin/songs/tin_roof.rb still use this one.)
  def self.ambient_walk(rate, lo, hi)
    rate.hz.lfo.square.sample_hold.smooth(1.0 / rate).at(lo..hi)
  end

  # The library's drift() in the shape of .ambient_walk: +rate+ new points
  # a second between +lo+ and +hi+, each glided to over a whole step along
  # a smoothstep, starting from the middle (as the old walk did: the drone
  # starts on its designed beats and only then wanders; textures-2,
  # 2026-10-15, after the maintainer preferred the old drone to a drift
  # starting at a random point).
  def self.ambient_drift(rate, lo, hi)
    drift(rate, range: lo..hi, smooth: :smoothstep, from: (lo + hi) / 2.0)
  end

  # A singing bowl struck by +strike+ (impulses; their heights are the
  # force) at +freq+ (Hz, a number or a node): the :bowl modal resonator
  # (four partials at bowl-like inharmonic ratios, each a doublet a little
  # apart (+beat+ Hz for the first, wider above: beating), higher partials
  # dying sooner (+decay+ seconds for the first); see
  # GraphNode::ModalResonator).  +flat+ in cents.  Until textures-1
  # (2026-10-14) this was a sum of eight pings; the modal bank is the same
  # sound (an 8-bar render nulls to -85 dB below its peak) at about a
  # sixth of the cost (10.5 against 66.7 ns/sample per voice).
  def self.ambient_bowl(strike, freq, flat: 0, decay: 24, beat: 0.7)
    freq *= 2 ** (-flat / 1200.0)
    strike.resonate(:bowl, freq, decay: decay, beat: beat, normalize: false)
  end

  # Dry stereo +sig+ plus a reverb of it scaled by +space+ (a number or a
  # node): the reverb is wet-only, so a knob can scale it.  The dry part
  # waits in silence for the reverb's tail (a sum ends when any of its
  # inputs ends).
  def self.ambient_room(sig, space: 0.5, decay: 8, room_size: 0.9)
    wet = sig.reverb(room_size: room_size, decay: decay, damping: 0.55, predelay: 0.03, dry: 0, wet: 1)
    sig.and_then(silence(decay * 2)) + wet * space
  end

  # Tape wear (+wear+ 0..1, a number or a node; 0.6 by default since
  # textures-5): wow (a slowly wandering delay), grain, and a lowpass that
  # falls with wear.  The grain is a dithered quantizer (textures-4,
  # 2026-10-15; the maintainer: "go with 10-bit for the tape hiss for
  # now", then "-10 to -7 bits of noise?"): 12 bits at wear 0, 10 at the
  # default 0.6, 7 at wear 1 (textures-7, the maintainer: "12 bit default
  # baseline, 10 bit at 0.6, keep 1.0 as is"; #ambient_tape_step).  Wear
  # alone wouldn't add noise (generational copying would), so the grain is
  # impressionistic, not a model of a real tape.  Dithered quantizing leaves only
  # a hiss-like grain, where the earlier sample-rate crush (decimate(16000
  # - wear * 11000, mix: wear * 0.6), textures-1/2) left images of each
  # note (the rate plus and minus it) that rang as a high metallic tone.
  #
  # The dither is triangular (TPDF, two uniform noises, a step either way;
  # textures-5, 2026-10-16): the grain is a steady hiss that doesn't
  # follow the sound, like a tape's noise floor.  The half-step uniform
  # dither before it (textures-4) left silence silent, so the grain
  # faded with each note's tail (the maintainer: "I feel like the noise
  # goes down as the amplitude goes down"; measured on a 220 Hz tail at
  # wear 0.6: the grain held at -61 dBFS while the tail was above -55 dBFS
  # and fell to -88 below it; TPDF stays at -60..-62).  Each channel of a
  # bundle gets its own hiss (a stereo tape has two tracks), and the wow
  # is shared (one transport).  The lowpass comes after the grain, so the
  # hiss is tape-dark too.  A node wear (a knob) moves the step every
  # sample through a lookup curve, quantizing without antialiasing (the
  # dither makes it noise anyway).
  #
  # The tape stops with the sound (textures-5 round 2; the maintainer:
  # the hiss should stop with the tail, and the tape end when its source
  # ends): the hiss runs while the input sounds (above -90 dB), for
  # +stop+ seconds after it falls silent, then fades out over 0.3 s
  # (GraphNode#sounding; one gate for every channel, like one tape
  # transport: open while any channel sounds), and the tape ends that fade
  # after its input ends, so renders end on their own instead of hissing to
  # the runner's 10 s cap.
  #
  # +bits+ (a number) sets the grain's depth directly, overriding wear's
  # (wear still sets the lowpass); textures-6, to compare 12 and 10 bits
  # with the room-then-tape order and TPDF dither.
  def self.ambient_tape(sig, wear: 0.6, stop: 1, bits: nil)
    wow = sig.delay(0.37.hz.lfo.sine.at(0.006..0.009) + ambient_drift(1.3, -0.0007, 0.0007))
    step = bits ? 2.0**(1 - bits) : ambient_tape_step(wear)
    running = sig.sounding(hold: stop, fade: 0.3)
    hiss = Array.new(wow.channel_count) { (noise.at(step * 0.5) + noise.at(step * 0.5)) * running }
    hiss = hiss.length == 1 ? hiss[0] : channels(*hiss)
    # The tape ends with its signal (the hiss's gate holds a little longer)
    grain = (wow + hiss).ring(:first).quantize(step)
    grain.filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6)
  end

  # The tape's quantizer step for +wear+ (a number or a node): 2^(1 -
  # bits), with bits the quadratic 12 - 5/6 wear - 25/6 wear^2 through 12
  # bits at wear 0, 10 at 0.6, and 7 at 1 (textures-7; falling everywhere
  # on 0..1, gently at first), so the step grows 32x (a node through a
  # lookup curve; the curve's Proc uses only literals and its own
  # parameter, so graph documents load it without trust).
  def self.ambient_tape_step(wear)
    if wear.is_a?(Numeric)
      w = wear.clamp(0, 1)
      return 2.0**((5 * w + 25 * w * w) / 6.0 - 11)
    end

    wear.aease(->(t) { (2**((5 * t + 25 * t * t) / 6.0) - 1) / 31.0 }, out: 2.0**-11..2.0**-6)
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
  # to the other side by +spread+ (0 mono, 1 hard left and right; a
  # number or a node such as a knob), so the shimmer sparkles across the
  # stereo field.
  #
  # patches-2 (2026-10-13: "a little more tonality and resonance in the
  # shimmer would be good") added seven partials 44-90 times the pitch, in
  # mono (`partials: 7, spread: 0` is close to it; ring: 0 is the earlier
  # noise-only shimmer); patches-3 (2026-10-13: "Having more shimmer
  # partials to spread around would be even better") has 16, wider.
  #
  # +tune+ (semitones, a number or a node such as a knob; 0 by default)
  # moves the whole shimmer up or down: the partials and the noise band
  # they ring from, keeping their spacing (the low partials stay on the
  # note).  -12 is a darker, closer shimmer; +7 a glassier one (up to
  # +12 at D2: higher, the top partials near the Nyquist frequency).
  # patches-4 (2026-10-13; maintainer on the 16 partials: "Could be a good
  # knob on the gong to change the shimmer tuning up or down"); patches-5
  # (2026-10-13) made the maintainer's pick, -7, the default (AMBIENT_GONG_TUNE),
  # and let +spread+ take a node ("Is the shimmer width adjustable?"; the
  # script's --spread, the preset's spread param, genre :ambient's
  # :spread knob).
  def self.ambient_gong_voice(midi, freq: 55.0, glide: 0.05, shimmer: 0.07, ring: 0.6, ring_decay: 0.8, partials: 16, spread: AMBIENT_GONG_SPREAD, space: 0.5, tune: AMBIENT_GONG_TUNE)
    # (the shimmer's frequency ratio; a plain 0 leaves the graph as before 2026-10-13)
    up = 2 ** (tune / 12.0)
    up = nil if up.is_a?(Numeric) && up == 1
    gong = synth(midi, voices: 1) { |n|
      hit = n.trigger
      fall = adsr(0, 4, 0, 0, trigger: hit, curve: :linear)
      f = freq * 2 ** ((n.number - D2.number) / 12.0)
      ratios = [1.0, 1.47, 2.02, 2.51, 2.97, 3.58, 4.23, 5.06, 5.91, 6.8]
      low = ratios.map.with_index { |r, i|
        hit.ping(f * r * (1 + fall * glide), decay: 24.0 / (1 + i * 0.35)) * (0.6 / (1 + i * 0.25))
      }.reduce(:+)
      swell = n.env(2.2, 7, 0, 3, curve: :swell, gm: false)
      band = noise.filter(:bandpass, cutoff: up ? ambient_walk(0.7, 2400, 5200) * up : ambient_walk(0.7, 2400, 5200), quality: 1.5)
      if ring > 0
        top = up ? f * up : f
        sides = ambient_gong_shimmer(partials).each_with_index.group_by { |_r, i| i % 2 }.values.map { |rs|
          rs.map { |(r, g), _i|
            band.ping(top * r * (1 + fall * glide * g), decay: ring_decay * (60.0 / r)**0.5)
          }.reduce(:+)
        }
        # (each side's resonator sum is about 51 sqrt(partials) times the band's RMS at 0.8 s, RMS growing about
        # as decay ** 0.6; AMBIENT_GONG_RING keeps patches-2's tonal level, about 0.8 sqrt(ring) times the band,
        # in each channel at any spread)
        k = Math.sqrt(ring) / (AMBIENT_GONG_RING * Math.sqrt(partials)) * (0.8 / ring_decay)**0.6
        l, r = sides.length == 2 ? sides : [sides[0], sides[0] * 0]
        noise_part = (band * Math.sqrt(1 - ring) * swell * shimmer).pan(0.2)
        if spread.is_a?(Numeric)
          a = (1 + spread) / 2.0
          b = (1 - spread) / 2.0
          # (spread 1: no cross terms, so no 0 * x for the plan to fold)
          mixed = b == 0 ? stereo(l * a, r * a) : stereo(l * a + r * b, l * b + r * a)
          air = noise_part + mixed * (swell * shimmer * (k / Math.sqrt(a * a + b * b)))
        else
          # (the same mix with spread a node: each side's share a, the
          # other's b, the power kept by 1 / sqrt(a^2 + b^2) = sqrt(2 / (1 + spread^2)))
          a = spread * 0.5 + 0.5
          b = spread * -0.5 + 0.5
          norm = (spread * spread + 1) ** -0.5 * (k * Math.sqrt(2))
          air = noise_part + stereo(l * a + r * b, l * b + r * a) * (swell * shimmer * norm)
        end
      else
        air = (band * swell * shimmer).pan(0.2)
      end
      low = low.filter(:highpass, cutoff: 38, quality: 0.6) * 0.12
      stereo(low, low) + air
    }
    ambient_room(gong, space: space, decay: 10, room_size: 1.0)
  end

  # Calibration of ambient_gong_voice's shimmer resonators (see there).
  AMBIENT_GONG_RING = 63.0

  # ambient_gong_voice's default shimmer tuning in semitones (patches-5,
  # 2026-10-13: the maintainer's pick of patches-4's tune variants; 0
  # before) and stereo spread of its shimmer partials (0 mono .. 1 hard
  # left and right).
  AMBIENT_GONG_TUNE = -7
  AMBIENT_GONG_SPREAD = 0.7

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
  # a small room (+space+), recorded on worn tape (+wear+).
  def self.ambient_koto_voice(midi, wear: 0.6, space: 0.5, level: 0.11, pan: -0.15)
    keys = synth(midi, voices: 4) { |v|
      body = v.hz.transpose(0).sine.at(0.9) * v.env(0.002, 1.8, 0.15, 1.5, gm: false)
      tine = v.hz.transpose(12 * Math.log2(7)).sine.at(0.25) * v.env(0.001, 0.25, 0, 0.2, gm: false)
      v.hz.pm(body + tine) * v.env(0.004, 3.2, 0.0, 1.6, gm: false) * (v.velocity * 0.5 + 0.5)
    }
    ambient_tape(ambient_room((keys * level).pan(pan), space: space, decay: 6, room_size: 0.7), wear: wear)
  end

  # The harp: soft Karplus-Strong plucks (MB::Sound.pluck_voice) in a
  # small room (+space+), recorded on worn tape (+wear+): the room goes on
  # the tape (textures-5; the room came after the tape before), so the
  # tail is worn and hissy like the notes.
  def self.ambient_harp_voice(midi, wear: 0.6, space: 0.5, level: 0.14, pan: 0.3, sustain: 2.5, brightness: 5)
    harp = synth(midi, voices: 3) { |v| pluck_voice(v, sustain: sustain, brightness: brightness) }
    ambient_tape(ambient_room((harp * level).pan(pan), space: space, decay: 5, room_size: 0.6), wear: wear)
  end

  # Two old sine generators per side on +root+ (Hz, a number or a node):
  # the root, a fifth (+0.31 Hz), and an octave, each drifting by a slow
  # random walk (a fraction of a hertz) and beating against the others; a
  # little warmth, a 900 Hz lowpass.  Stereo.
  def self.ambient_drone(root, level: 1.0)
    side = ->(spread) {
      gen = ->(f, depth) { (f + ambient_drift(0.05, -depth, depth)).tone.sine }
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
      clicks = dust(700)
      pitch = noise.sample_hold(clicks) * 1800 + 4200
      where = adsr(0, across, 0, 0, trigger: n.trigger, curve: :linear) * 1.4 - 0.7 # right to left
      (clicks.ping(pitch, decay: 0.012) * 0.25 * swell).pan(where)
    }
    stick * level
  end

  # The script's instruments by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  def self.ambient_patch(midi, patch = :bowl, space: 0.5, wear: 0.6, tune: AMBIENT_GONG_TUNE.to_f, spread: AMBIENT_GONG_SPREAD)
    case patch
    when :bowl then ambient_bowl_voice(midi, space: space.constant.named('space'))
    when :rin then ambient_rin_voice(midi, space: space.constant.named('space'))
    when :gong
      ambient_gong_voice(midi, space: space.constant.named('space'), tune: tune.constant.named('tune'), spread: spread.constant.named('spread'))
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
      wear: [0.6, Float, '-w', 'Tape wear 0..1 (koto, harp): 12 bits of grain at 0, 10 at 0.6, 7 at 1', 0.0..1.0],
      tune: [AMBIENT_GONG_TUNE.to_f, Float, '-t', 'Gong shimmer tuning in semitones (the shimmer partials and their noise band)', -24.0..12.0],
      spread: [AMBIENT_GONG_SPREAD, Float, '-S', 'Gong shimmer stereo width: 0 mono, 1 every other partial hard left and right', 0.0..1.0],
    ) { |midi, p|
      ambient_patch(midi, p.patch, space: p.space, wear: p.wear, tune: p.tune, spread: p.spread)
    }
  end
end
