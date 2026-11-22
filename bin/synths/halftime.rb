#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Half-time drum & bass sounds (a ghost voice, a talking FM sub, tape pads, a notch Reese, a clack kit; rain and vinyl textures), playable from MIDI.
#
# Where they came from: the persona panel's third round (the dry run of
# 2026-11-09/10), in which the fictional producer Kez Volta (who also wrote
# "Tunnel Vision", bin/synths/dnb.rb) wrote the half-time B-side "N109"
# (bin/songs/n109.rb), then a second version after the producer's listen.
# The song's sounds moved here as library presets (n109-1, 2026-11-22),
# named for what they are and tagged n109 for where they came from.
#
# Patches (-p):
#   ghost_voice    one sung phrase's synth: two saws (one a hair sharp, each
#                  with its own vibrato) through alto formants morphing over
#                  a bar; the variant knob breathes it (below)
#   talking_sub    a sine with whole-number FM on top so it locks to the
#                  note: 3x as each note speaks, 4x breathing over four bars,
#                  lowpassed (--attack 1.2 is the song's quiet swell)
#   tape_pad       two saws and an octave triangle per note, a dark lp4,
#                  a slow swell, through a wobbling delay (tape wow), a
#                  highpass, and a Juno chorus (stereo)
#   tape_pad_high  the pad's octave: a triangle and a quiet sharp saw, a
#                  brighter lp4, slower swell, the same wow and chorus
#   notch_reese    two saws beating about once a second plus an octave,
#                  driven into a softclipper BEFORE a dark lp4 (--cutoff), a
#                  low cut, and a notch swinging over three bars: it aches,
#                  it doesn't snarl
#   clack_kit      a drum kit: a small kick, a woody FM clack for a snare,
#                  a clap that gives the clack weight, an FM rim click, metal
#                  hats, a noise shaker, a ride (GM notes; the variant knob
#                  weighs the clap)
# Textures (presets, not -p patches: they ignore notes and play until
# stopped): window_rain (drops ringing on glass, a dark bed, wandering
# across the stereo field; the variant knob takes it outside), vinyl_specks
# (bandpassed specks and a scratch every couple of seconds).
#
# The variant knob (n109-1, 2026-11-22; the maintainer: "Add the
# instruments from the song to the library ... with a knob to fade from v1
# to v2 variants on the instruments"): ghost_voice, window_rain, and
# clack_kit take a param `variant`, 0..1, 0 the first version's sound and 1
# the second's.  Every setting the versions differ in fades by one law:
# levels and times geometrically (evenly in dB and in log time), a layer
# only one version has by its amplitude, sqrt(variant) in and
# sqrt(1 - variant) out (equal power for an uncorrelated layer).  A number
# 0 or 1 builds exactly that version's graph (a layer it lacks is not
# built), so the song renders each version as written; a node (a param, a
# knob) builds both layers, so it turns live (`turn :"voice/variant", 1,
# over: 8.bars`).  What the knob fades:
#   ghost_voice  saws 0 dB -> -6.9 dB (0.45), the highpassed air (noise at
#                0.05) out, the breath (noise in narrow bands at the note
#                and its 2nd and 3rd harmonics, plus a little hiss, at 2)
#                in, attack 40 -> 70 ms, release 250 -> 300 ms, output
#                0 -> +2 dB (the song raised every use of the voice 2 dB)
#   window_rain  level 0 -> -3 dB; with space (the preset) the hall wet
#                -18 -> -5 dB and the dub echo in at -12 dB (in the song
#                those are its bus sends, faded by the same laws)
#   clack_kit    the clap 0.45 -> 0.6 (+2.5 dB: more weight under the clack)
#
# Every patch is a method taking a MIDI source (Notes, Clip, MIDI file, or
# Stream) and its knobs as keywords (ghost_voice(midi, variant: 0.5),
# talking_sub(midi, attack: 1.2), clack_kit(grid, variant: 1)), and a
# preset (presets/<name>.mbg.rb): `preset :ghost_voice, midi: clip,
# variant: 1`, `L.inst.ghost_voice`, `track :voice, :ghost_voice`.
#
# Usage:
#     bin/synths/halftime.rb -p ghost_voice --variant 1        # live MIDI, the breathy one
#     bin/synths/halftime.rb -p talking_sub song.mid sub.flac
#     bin/synths/halftime.rb -p clack_kit spec/test_data/c2_sustain.mid kit.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/halftime.rb'`):
#     bpm 174
#     track :voice, seq(C4.n4, Eb4.n4, F4.n2, R.n1).legato(1).loop, :ghost_voice
#     turn :"voice/variant", 1, over: 8.bars      # fade the ghost from v1 to v2
#     bg :rain, preset(:window_rain, variant: 0)  # on the desk; variant: 1 outside the window
#     bg :sub, talking_sub(seq(F1, T, T, T, Gb1, T, T, R).n4.loop) * 0.5
#     bg :drums, clack_kit(grid(16, kick: 'X.........x.....', snare: '........X.......', hat: 'x...x...x...x...').loop)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The variant param every halftime entry with versions has (see the
  # header): 0 the first version's sound, 1 the second's.
  HALFTIME_VARIANT = [0.0, 0.0..1.0, 'Version: 0 the first (v1), 1 the second (v2); in between fades every setting that differs'].freeze

  # A setting that is +a+ in the first version and +b+ in the second, at
  # +variant+ (a number or a node, 0..1): geometric (+law+ :geometric,
  # evenly in dB for gains and in log time for times; +a+ and +b+ the same
  # sign) or :linear.  A number 0 or 1 gives +a+ or +b+ exactly.
  def self.variant_fade(a, b, variant, law: :geometric)
    if variant.is_a?(Numeric)
      return a if variant == 0
      return b if variant == 1

      law == :linear ? a + (b - a) * variant : a * (b.to_f / a)**variant
    else
      law == :linear ? variant * (b - a) + a : ((b.to_f / a)**variant) * a
    end
  end

  # The amplitude of a layer only one version has: +side+ :in (the second
  # version's: sqrt(variant)) or :out (the first's: sqrt(1 - variant)), so
  # an uncorrelated layer crossfades at equal power.  A number gives a
  # number.
  def self.variant_layer(variant, side)
    if variant.is_a?(Numeric)
      Math.sqrt(side == :in ? variant : 1 - variant)
    else
      (side == :in ? variant : variant * -1 + 1)**0.5
    end
  end

  # Whether a layer of +side+ (see .variant_layer) is built at +variant+:
  # a number 0 has no :in layer and 1 no :out layer; a node has both.
  def self.variant_builds?(variant, side)
    return true unless variant.is_a?(Numeric)

    side == :in ? variant != 0 : variant != 1
  end

  # The vowels the ghost voice sings over a bar ("ah-oh-oo").
  GHOST_VOWELS = %i[a o u].freeze

  # The ghost voice: two saws (the second 0.11 semitones sharp and 0.6 as
  # loud, each with its own 5.3 Hz vibrato of 2.2 Hz), gliding 110 ms
  # between notes, through alto formants morphing through +vowels+ once a
  # bar.  +variant+ (a number or a node; see the header) fades from the
  # first version (the saws plus a breath of highpassed noise) to the
  # second (mostly breath: noise in narrow bands at the note and its 2nd
  # and 3rd harmonics, about 3 dB over the saws, a slower attack).
  # Mono, one voice.  In N109 it sings one phrase, bounced, and is
  # played back off the keys like a sample after that.
  def self.ghost_voice(midi, vowels: GHOST_VOWELS, variant: 0)
    saw_gain = variant_fade(1.0, 0.45, variant)
    attack = variant_fade(0.04, 0.07, variant)
    release = variant_fade(0.25, 0.3, variant)
    out = synth(midi, voices: 1) { |v|
      p = v.hz.glide(110.ms)
      vib = -> { 5.3.hz.at(2.2) } # a little vibrato
      # (the first version's air draws its noise seed first, so a variant
      # knob at 0 is the first version sample for sample; at 1 the breath
      # is the second version's with another noise draw)
      air = noise.filter(:highpass, cutoff: 1500) if variant_builds?(variant, :out)
      if variant_builds?(variant, :in)
        # Breath: noise squeezed through narrow filters AT the sung pitch
        # and its 2nd and 3rd harmonics, so it's air that still carries
        # the tune.
        f = v.freq
        breath = noise.filter(:bandpass, cutoff: f, quality: 14) * 5 +
                 noise.filter(:bandpass, cutoff: f * 2, quality: 14) * 3 +
                 noise.filter(:bandpass, cutoff: f * 3, quality: 12) * 2 +
                 noise.filter(:highpass, cutoff: 2500) * 0.06
      end
      saws = p.fm(vib.()).saw + p.transpose(0.11).fm(vib.()).saw * 0.6
      src = saw_gain == 1 ? saws : saws * saw_gain
      src += air * mul(0.05, variant_layer(variant, :out)) if air
      src += breath * mul(2, variant_layer(variant, :in)) if breath
      src.formant(*vowels, morph: 1.bar.lfo.at(0.0..1.0), voice: :alto) * v.amp_env(attack, 0.2, 0.85, release)
    }
    level = variant_fade(1.0, 2.db.to_f, variant)
    level == 1 ? out : out * level
  end

  # +a+ times +b+ (numbers or nodes), a number times 1 being the number.
  def self.mul(a, b)
    return a if b.is_a?(Numeric) && b == 1

    b.is_a?(Numeric) ? a * b : b * a
  end

  # Rain on the glass: drops (about +density+ a second, seeded by +seed+,
  # random heights) ringing a resonator at a random pitch each between
  # +low+ and +high+ Hz, a bed of dark noise at +bed+ (nil for none),
  # wandering across the stereo field +pan_rate+ times a second.  Stereo;
  # it ignores +_source+ (notes) and plays until stopped.  +variant+ (see
  # the header) takes it from on the desk (the first version) to outside
  # the window (3 dB down; with +space+, wetter): +space+ (true, the
  # preset) adds a highpassed hall and a dub echo inside; the song sends
  # to its own buses instead (space: false).
  def self.window_rain(_source = nil, density: 160, low: 2500, high: 7000, bed: -30.db, pan_rate: 1, seed: 1, variant: 0, space: false)
    drops = dust(density, range: 0.05..1, seed: seed)
    dry = drops.ping(noise.sample_hold(drops).at(low..high), decay: 0.02) * 0.12
    dry += noise.lp4(3000).at(bed) if bed
    dry = dry.pan(drift(pan_rate))
    gain = variant_fade(1.0, -3.db.to_f, variant)
    dry *= gain unless gain == 1
    return dry unless space

    hall = (dry * variant_fade(-18.db.to_f, -5.db.to_f, variant)).filter(:highpass, cutoff: 400).reverb(:hall, mix: 1)
    wet = dry + hall
    if variant_builds?(variant, :in)
      echo = dry * mul(-12.db.to_f, variant_layer(variant, :in))
      wet += echo.ping_pong(3.n16, feedback: 0.5).filter(:lowpass, cutoff: 2400).filter(:highpass, cutoff: 400)
    end
    wet
  end

  # Vinyl specks: bipolar dust about +density+ a second through a
  # 1400 Hz bandpass, plus a scratch (a highpassed click) at most every
  # 1.8 seconds.  Mono; it ignores +_source+ and plays until stopped.
  def self.vinyl_specks(_source = nil, density: 14)
    specks = dust(density, bipolar: true).filter(:bandpass, cutoff: 1400, quality: 0.7) * 0.6
    scratch = dust(100, min_gap: 1.8.seconds, range: 0.6..1).filter(:highpass, cutoff: 300) * 0.5
    specks + scratch
  end

  # Exactly three times a pitch, in semitones.
  HALFTIME_X3 = 12 * Math.log2(3)

  # The talking sub: a sine whose own pitch FM-modulates it at exactly 3x
  # (index 90 Hz, as each note speaks: a grunt envelope) and 4x (two
  # octaves up, index 150 Hz, scaled by +talk+, a 0.1..1 swing over four
  # bars unless given), gliding 60 ms, an amplitude +attack+ in seconds
  # (1.2 for a swell), lowpassed at +cutoff+.  Mono, one voice.  The 3x is
  # what you hear on a phone; the fundamental is what you feel on a rig.
  def self.talking_sub(midi, attack: 0.03, cutoff: 420, talk: nil)
    talk ||= 4.bars.lfo.at(0.1..1.0)
    synth(midi, voices: 1) { |v|
      f = v.hz.glide(60.ms)
      grunt = v.env(0.004, 0.22, 0.3, 0.05)
      f.fm(f.transpose(HALFTIME_X3).at(90) * grunt + f.transpose(24).at(150) * talk * grunt) * v.amp_env(attack, 0.1, 1.0, 0.1)
    }.filter(:lowpass, cutoff: cutoff)
  end

  # Tape wow: a delay time wandering 4-8 ms with a 6 Hz flutter, for the
  # tape pads.
  def self.halftime_wow
    drift(0.8, smooth: :cosine).at(0.004..0.008) + 6.hz.lfo.at(0.0001)
  end

  # The tape pad: per note two saws (one 0.12 semitones flat) and a quiet
  # triangle an octave up, through lp4 at +cutoff+, a slow swell
  # (+attack+, +release+), then tape wow (a wobbling delay), a 180 Hz
  # highpass, and a Juno chorus.  Stereo, eight voices.
  def self.tape_pad(midi, cutoff: 900, attack: 0.9, release: 1.4)
    pad = synth(midi, voices: 8) { |v|
      (v.hz.saw + v.hz.transpose(-0.12).saw + v.hz.transpose(12.05).triangle * 0.4).lp4(cutoff, resonance: 0.1) * v.amp_env(attack, 0.5, 0.85, release)
    }
    pad.delay(halftime_wow).filter(:highpass, cutoff: 180).chorus
  end

  # The tape pad's high layer (play it an octave up): a triangle and a
  # quiet saw 0.1 semitones sharp per note through a brighter lp4, a
  # slower swell, the same wow and chorus (no highpass).  Stereo.
  def self.tape_pad_high(midi, cutoff: 2200, attack: 1.2, release: 1.6)
    hi = synth(midi, voices: 8) { |v|
      (v.hz.triangle + v.hz.transpose(0.1).saw * 0.3).lp4(cutoff, resonance: 0.1) * v.amp_env(attack, 0.5, 0.8, release)
    }
    hi.delay(halftime_wow).chorus
  end

  # The notch Reese: two saws 0.09 semitones either side of the note
  # (beating about once a second) plus a quiet saw an octave up, gliding
  # 60 ms, driven (+drive+) into a softclipper BEFORE a dark lp4 at
  # +cutoff+ (a number or a node: N109 opens it 420 -> 1300 Hz over 16
  # bars), two 120 Hz highpasses off the sub, and a notch swinging 500 to
  # 1400 Hz over +notch_bars+ bars.  Mono, one voice.
  def self.notch_reese(midi, cutoff: 800, drive: 5, notch_bars: 3)
    reese = synth(midi, voices: 1) { |v|
      f = v.hz.glide(60.ms)
      (f.transpose(-0.09).saw + f.transpose(0.09).saw + f.transpose(12.04).saw * 0.3) * v.amp_env(0.06, 0.2, 0.9, 0.2)
    }
    (reese * drive).softclip(0.25, 0.8)
      .lp4(cutoff, resonance: 0.18)
      .filter(:highpass, cutoff: 120).filter(:highpass, cutoff: 120)
      .filter(:notch, cutoff: notch_bars.bars.lfo.at(500..1400), quality: 1.6)
  end

  # The clack kit's voices: a block for `kit` (a Drums::Machine builder).
  CLACK_VOICES = proc {
    voice(:kick, tune: 78) { |h|
      (h.body(h.tune, decay: 0.3, sweep: 2.6) * 1.3 + h.click(0.25)).filter(:highpass, cutoff: 70, quality: 0.7).softclip(0.6, 1.0)
    }
    # A clack more than a snare: woody FM knock, short noise, a bit of body.
    voice(:snare) { |h|
      (h.fm(820, ratio: 1.83, index: 3.0, decay: 0.07, index_decay: 0.02) * 0.7 +
        h.body(235, decay: 0.16, sweep: 1.4) * 0.8 +
        h.noise(decay: 0.22, highpass: 1500).filter(:lowpass, cutoff: 9000) * 0.5).softclip(0.5, 1.0)
    }
    # The weight that turns the clack into a snare when it goes two-step.
    voice(:clap, weight: 0.45) { |h|
      (h.body(196, decay: 0.24, sweep: 1.5) * 0.7 + h.noise(decay: 0.38, highpass: 1900).filter(:lowpass, cutoff: 10000) * 0.5).softclip(0.5, 1.0) * h.weight
    }
    voice(:rim) { |h| h.fm(1400, ratio: 2.41, index: 1.2, decay: 0.025, index_decay: 0.008) * 0.8 }
    voice(:hat, decay: 0.03) { |h| h.metal.filter(:highpass, cutoff: 9000).filter(:lowpass, cutoff: 13000) * h.env(h.decay) * 9 }
    voice(:open_hat, decay: 0.09) { |h| h.noise(decay: 0.09, highpass: 6000).filter(:lowpass, cutoff: 11000) * 0.5 }
    voice(:ride, decay: 0.2) { |h| h.metal.filter(:bandpass, cutoff: 6200, quality: 1.2) * h.env(h.decay) * 5 }
  }

  # The clack kit's drum machine (a Drums::Machine; play it with
  # `.kit(source, clap: { weight: 0.6 })`, or use .clack_kit).
  def self.clack_machine
    kit(&CLACK_VOICES)
  end

  # The clap's weight at +variant+ (see the header): 0.45 -> 0.6.
  def self.clack_clap(variant)
    variant_fade(0.45, 0.6, variant)
  end

  # The clack kit playing +source+ (a grid Kit, a clip, or MIDI with GM
  # drum notes), the clap weighed by +variant+.
  def self.clack_kit(source, variant: 0)
    kit(source, clap: { weight: clack_clap(variant) }, &CLACK_VOICES)
  end

  # The patches and textures: +:about+ (the preset's description after
  # where it came from), +:tags+, +:knobs+ ({ name => [default, range,
  # description] }: the preset's params), +:texture+ (ignores its notes;
  # not a -p patch), +:drums+ (plays GM drum notes), and +:build+, a Proc
  # of the MIDI source and the knobs (named Constants or numbers).
  HALFTIME_PATCHES = {
    ghost_voice: {
      about: 'A ghost of a voice: two saws (one a hair sharp, each with its own vibrato) through alto formants morphing ' \
             'ah-oh-oo over a bar; variant 1 is mostly breath (noise in narrow bands at the note and its 2nd and 3rd ' \
             'harmonics, about 3 dB over the saws) with a slower attack',
      tags: %i[halftime dnb n109 formant vocal breath lead variant],
      knobs: { variant: HALFTIME_VARIANT },
      build: ->(midi, k) { ghost_voice(midi, variant: k[:variant]) },
    },
    talking_sub: {
      about: 'A talking sub: a sine with whole-number FM on top so it locks to the note, 3x as each note speaks and 4x ' \
             'breathing over four bars, lowpassed (attack 1.2 for a swell)',
      tags: %i[halftime dnb n109 fm sub bass mono],
      knobs: {
        attack: [0.03, 0.001..4.0, 'Amplitude attack in seconds (1.2: a swell)'],
        cutoff: [420.0, 100.0..2000.0, 'Lowpass cutoff in Hz'],
      },
      build: ->(midi, k) { talking_sub(midi, attack: k[:attack], cutoff: k[:cutoff]) },
    },
    tape_pad: {
      about: 'A tape pad: two detuned saws and an octave triangle per note through a dark lp4, a slow swell, tape wow ' \
             '(a wobbling delay), a highpass, and a Juno chorus',
      tags: %i[halftime dnb n109 pad tape],
      knobs: {
        cutoff: [900.0, 100.0..8000.0, 'lp4 cutoff in Hz'],
        attack: [0.9, 0.001..8.0, 'Attack in seconds'],
        release: [1.4, 0.01..10.0, 'Release in seconds'],
      },
      build: ->(midi, k) { tape_pad(midi, cutoff: k[:cutoff], attack: k[:attack], release: k[:release]) },
    },
    tape_pad_high: {
      about: 'The tape pad\'s high layer (play it an octave up): a triangle and a quiet sharp saw per note through a ' \
             'brighter lp4, a slower swell, tape wow, and a Juno chorus',
      tags: %i[halftime dnb n109 pad tape],
      knobs: {
        cutoff: [2200.0, 100.0..8000.0, 'lp4 cutoff in Hz'],
        attack: [1.2, 0.001..8.0, 'Attack in seconds'],
        release: [1.6, 0.01..10.0, 'Release in seconds'],
      },
      build: ->(midi, k) { tape_pad_high(midi, cutoff: k[:cutoff], attack: k[:attack], release: k[:release]) },
    },
    notch_reese: {
      about: 'A Reese that aches instead of snarls: two saws beating about once a second plus an octave, driven into a ' \
             'softclipper before a dark lp4, a low cut, and a notch swinging over three bars',
      tags: %i[halftime dnb n109 bass mono],
      knobs: {
        cutoff: [800.0, 100.0..8000.0, 'lp4 cutoff in Hz (after the softclipper)'],
        drive: [5.0, 0.5..20.0, 'Gain into the softclipper'],
      },
      build: ->(midi, k) { notch_reese(midi, cutoff: k[:cutoff], drive: k[:drive]) },
    },
    clack_kit: {
      about: 'A half-time kit: a small kick, a woody FM clack for a snare, a clap that gives it weight, an FM rim click, ' \
             'metal hats, a noise shaker, and a ride (GM notes); variant 1 weighs the clap 2.5 dB more',
      tags: %i[halftime dnb n109 drums fm variant],
      drums: true,
      knobs: { variant: HALFTIME_VARIANT },
      build: ->(midi, k) { clack_kit(midi, variant: k[:variant]) },
    },
    window_rain: {
      about: 'Rain on the glass: drops ringing at random pitches, a dark noise bed, wandering across the stereo field, ' \
             'with its own hall and dub echo; variant 1 is 3 dB down and wetter (outside the window).  It ignores notes',
      tags: %i[halftime dnb n109 texture weather drops stereo variant],
      texture: true,
      knobs: {
        variant: HALFTIME_VARIANT,
        density: [160.0, 1.0..1000.0, 'Drops per second'],
      },
      build: ->(_midi, k) { window_rain(density: k[:density], variant: k[:variant], space: true) },
    },
    vinyl_specks: {
      about: 'Vinyl specks: bandpassed crackle and a scratch every couple of seconds, bone dry.  It ignores notes',
      tags: %i[halftime dnb n109 texture crackle noise],
      texture: true,
      knobs: { density: [14.0, 1.0..200.0, 'Specks per second'] },
      build: ->(_midi, k) { vinyl_specks(density: k[:density]) },
    },
  }.freeze

  # The patches -p plays (the textures ignore notes, so they are presets only).
  HALFTIME_PLAYABLE = HALFTIME_PATCHES.reject { |_, s| s[:texture] }.keys.freeze

  # Patch +patch+ (a HALFTIME_PATCHES name) playing +midi+, its knobs from
  # +knobs+ (numbers or nodes; numbers become Constants named after the
  # knob, so a saved document has them as params).
  def self.halftime_patch(midi, patch = :ghost_voice, **knobs)
    s = HALFTIME_PATCHES.fetch(patch) { raise ArgumentError, "Unknown halftime patch #{patch.inspect} (#{HALFTIME_PATCHES.keys.join(', ')})" }
    extra = knobs.keys - s[:knobs].keys
    raise ArgumentError, "Halftime patch #{patch} has no knob #{extra.map(&:inspect).join(', ')} (#{s[:knobs].keys.join(', ')})" unless extra.empty?

    k = s[:knobs].to_h { |name, (default, _range, _description)|
      value = knobs[name].nil? ? default : knobs[name]
      [name, value.is_a?(Numeric) ? value.to_f.constant.named(name.to_s) : value]
    }
    s[:build].call(midi, k)
  end

  # The description of +patch+ (the preset's).
  def self.halftime_description(patch)
    s = HALFTIME_PATCHES.fetch(patch)
    "#{s[:about]}.  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern " \
      'EDM / UK drum & bass producer-DJ, for the half-time B-side "N109" (bin/songs/n109.rb) in the persona panel\'s ' \
      'third round (2026-11-09/10).'
  end

  if main_script?(__FILE__)
    knob_names = HALFTIME_PLAYABLE.flat_map { |n| HALFTIME_PATCHES[n][:knobs].keys }.uniq
    synth_script(
      description: ->(p) { halftime_description(p.patch) },
      patch: [:ghost_voice, Symbol, '-p', 'Patch to play', HALFTIME_PLAYABLE],
      **knob_names.to_h { |n|
        users = HALFTIME_PLAYABLE.select { |name| HALFTIME_PATCHES[name][:knobs].key?(n) }
        specs = users.map { |name| HALFTIME_PATCHES[name][:knobs][n] }
        lo = specs.map { |s| s[1].begin }.min
        hi = specs.map { |s| s[1].end }.max
        [n, [nil, Float, "#{specs.first[2]} (#{users.map { |name| "#{name} #{HALFTIME_PATCHES[name][:knobs][n][0]}" }.join(', ')})", lo..hi]]
      },
    ) { |midi, p|
      s = HALFTIME_PATCHES.fetch(p.patch)
      bad = knob_names.reject { |n| p[n].nil? || s[:knobs].key?(n) }
      raise ScriptRunner::InputError, "#{p.patch} has no #{bad.map { |n| "--#{n.to_s.tr('_', '-')}" }.join(', ')} (its knobs: #{s[:knobs].keys.join(', ')})" unless bad.empty?
      halftime_patch(midi, p.patch, **s[:knobs].keys.to_h { |n| [n, p[n]] })
    }
  end
end
