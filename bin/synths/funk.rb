#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A funk / neo-soul one-man-band looping rig (mouth drums, percussion,
# bass, FM keys, clav, talkbox lead, choir, an audio looper), playable from
# MIDI.
#
# Where they came from: the persona panel experiment of 2026-10-13
# (research branch research-persona-looper, research/persona-panel/looper/),
# in which a fictional persona, Tiko Marvell (a funk / neo-soul live
# looper), built the set "Loop Church" (bin/songs/loop_church.rb) with the
# public API.  The patches moved here so they can be played, reused, and
# saved as presets, named for the genre (patches-2, 2026-10-13).
#
# Patches (-p):
#   beat      mouth drums: a short, dry tr808 kit (kick, snare, hats; GM note
#             map) half through a formant "mouth" (beatbox: true says each
#             drum through its own narrow vowel)
#   perc      shaker, rim, and congas (GM note map), highpassed
#   bass      a round funk bass: a sine body plus a lowpassed saw opening
#             with velocity; ghost notes are just thumps
#   keys      an FM electric piano: a 1:1 body whose index falls, a 14:1
#             tine bark for hard strikes, auto-pan tremolo
#   clav      a clav-ish stab: a narrow pulse, highpassed and quick
#   talkbox   the lead: a bright buzz an octave below the note through
#             narrow formants opening "u -> o -> a -> e" on every note,
#             delayed vibrato, a dotted-eighth echo
#   choir     a soft "ooh" choir (two saws through an alto formant), with
#             the audio looper behind it: --dub (the footswitch) sends the
#             voice into a 4-bar loop that loses 1 - --keep every pass
#
# Every patch is one method taking a MIDI source (Notes, Clip, MIDI file, or
# Stream) and its knobs as keywords: funk_beat, funk_perc, funk_bass_voice,
# funk_keys_voice, funk_clav_voice, funk_talkbox_voice, funk_choir_voice;
# the looper is the effect funk_dub_loop(sig, dub:, keep:).  Each is also a
# preset (presets/funk_*.mbg.rb): `preset :funk_keys, midi: midi`.
#
# Usage:
#     bin/synths/funk.rb                              # live MIDI, the keys
#     bin/synths/funk.rb -p talkbox song.mid lead.flac
#     bin/synths/funk.rb -p choir --dub 1 --keep 0.9 song.mid choir.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/funk.rb'`):
#     bpm 96
#     bg :keys, funk_keys_voice(seq([F3, A3, C4, E4].map(&:n4).reduce(:&), R.n4, [F3, B3, E4, A4].map(&:n4).reduce(:&), R.n4).loop)
#     bg :bass, funk_bass_voice(seq(D2, R, R, D2, R, R, A2, C3, R, R, D3, R, F2, R, E2, R).n16.loop)
#     bg :lead, funk_talkbox_voice(seq(A4, R, C5, D5, R, R, F5, E5, D5, R, R, C5, A4, R, R, R).n16.swing(0.57).loop)
#     knob :dub, 1; bg :choir, funk_choir_voice(seq([A3, D4, F4].map(&:n1).reduce(:&)).loop).then { |c| funk_dub_loop(c, dub: knob(:dub)) }

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # Mouth drums: a tr808 kit with short, dry voices (kick, snare, closed
  # and open hats) playing +source+ (a grid Kit, a clip, or MIDI), half of
  # it through a formant filter (+mouth+ wet) so it reads as a mouth more
  # than a machine.
  #
  # +beatbox+ (true, or 0..1) is a much more aggressive mouth: each drum
  # driven into a softclipper (so even the kick's sine has harmonics for
  # the formants to shape) and through its own narrow vowel, as a
  # beatboxer says them: the kick a bass "boo" (u to o), the snare a
  # tenor "ka" (a to e), the hats a soprano "ts" (i); +beatbox+ is the
  # share of those (power), the rest the plain kit.
  def self.funk_beat(source, mouth: 0.7, dry: 0.55, level: 2.0, beatbox: false)
    voices = {
      kick: { tune: 56, decay: 0.32, tone: 0.25 },
      snare: { tune: 210, decay: 0.16, tone: 0.55, snappy: 0.75 },
      closed_hat: { decay: 0.035, tone: 0.5 },
      open_hat: { decay: 0.22 },
    }
    unless beatbox
      kit = tr808(source, only: voices.keys, velocity_curve: :midi, **voices)
      vowel = kit.formant(:o, :u, morph: 0.4, width: 1.6)
      return (kit * dry + vowel * mouth).softclip(0.7, 0.95) * level
    end

    amount = beatbox == true ? 1.0 : beatbox.to_f
    outs = tr808(source, only: voices.keys, velocity_curve: :midi, outputs: :separate, **voices)
    say = {
      kick: [[:u, :o], :bass, 0.35, 6],
      snare: [[:a, :e], :tenor, 0.4, 3],
      closed_hat: [[:i], :soprano, 0.5, 2],
      open_hat: [[:i, :e], :soprano, 0.5, 2],
    }
    said = outs.names.map { |n|
      vowels, voice, width, drive = say.fetch(n)
      (outs[n] * drive).softclip(0.3, 0.95).formant(*vowels, morph: 0.5, voice: voice, width: width) * (3.5 / drive)
    }.reduce(:+)
    mix = said * Math.sqrt(amount)
    mix += outs.names.map { |n| outs[n] }.reduce(:+) * (Math.sqrt(1 - amount) * dry) if amount < 1
    mix.softclip(0.7, 0.95) * level
  end

  # The overdub percussion: shaker, rim, congas (+source+ as for
  # .funk_beat), highpassed at 180 Hz.
  def self.funk_perc(source, level: 1.2)
    tr808(source, only: [:maracas, :rimshot, :low_conga, :mid_conga], velocity_curve: :midi, maracas: { decay: 0.05 }, rimshot: { tune: 1700 }, low_conga: { tune: 190 }, mid_conga: { tune: 280 })
      .filter(:highpass, cutoff: 180) * level
  end

  # A round funk bass: sine body plus a lowpassed saw that opens with
  # velocity (up to +bite+ Hz above 160), short and punchy; ghost notes are
  # just thumps.
  def self.funk_bass_voice(midi, bite: 1400, level: 0.55)
    synth(midi, voices: 2) { |v|
      f = v.hz
      env = v.amp_env(0.003, 0.5, 0.55, 0.05)
      cut = v.filter_env(0.002, 0.18, 0.15, 0.05) * v.velocity * bite + 160
      ((f.sine * 0.8 + f.saw.lp4(cut, resonance: 0.25) * 0.55) * env)
    }.softclip(0.6, 0.95) * level
  end

  # FM electric piano: a 1:1 body pair whose index falls (+body+), a 14:1
  # tine bark for hard strikes (+tine+), auto-pan at +tremolo+ Hz.
  def self.funk_keys_voice(midi, level: 1, body: 0.25, tine: 0.18, tremolo: 4.5)
    synth(midi, voices: 8, retrigger: :string) { |v|
      body_mod = v.hz.sine.free * v.fm_env(0, 2.0, 0, 0.5) * body
      body_osc = v.hz.sine.free.pm(body_mod)
      tine_mod = v.hz.transpose(Math.log2(14).oct).sine.free * v.fm_env(0, 0.3, 0, 0.1) * v.velocity * tine
      tine_osc = v.hz.sine.free.pm(tine_mod)
      (body_osc + tine_osc * 0.6) * v.amp_env(0.002, 3.0, 0, 0.25) * 0.35
    }.softclip(0.8, 0.95).filter(:highpass, cutoff: 160).pan(tremolo.hz.lfo.at(0.35)) * level
  end

  # A clav-ish stab: a narrow pulse (+width+), highpassed and quick.
  def self.funk_clav_voice(midi, width: 0.2, cutoff: 3500, level: 0.6)
    synth(midi, voices: 4) { |v|
      v.hz.pulse(width).filter(:highpass, cutoff: 400).lp4(cutoff) * v.amp_env(0.001, 0.12, 0, 0.04) * level
    }
  end

  # The talkbox lead: a glided buzz (saw and narrow pulse) +octave+
  # octaves below the note, brightened (+air+, a highpassed copy added:
  # a talkbox wants a bright carrier), through narrow formants (+width+)
  # that open "u -> o -> a -> e" on every note (a filter envelope driving
  # the morph) and a little saturation, with a delayed vibrato and a
  # dotted-eighth echo (+echo+ wet).
  #
  # patches-2 (2026-10-13; maintainer: "Not talkboxy enough; needs maybe
  # an octave lower input with some more top end and more aggressive
  # formants"): before, the buzz was at the note, unbrightened, through
  # "o -> a -> e" formants at width 1.0 (`octave: 0, air: 0, width: 1.0,
  # vowels: [:o, :a, :e]` is close to it).
  def self.funk_talkbox_voice(midi, level: 1, echo: 0.22, glide: 0.045, octave: -1, air: 0.7, width: 0.45, vowels: [:u, :o, :a, :e])
    synth(midi, voices: 1) { |v|
      f = v.hz.glide(glide).vibrato(5.2, depth: 0.25, delay: 0.25)
      buzz = f.transpose(12 * octave)
      src = buzz.saw * 0.6 + buzz.pulse(0.2) * 0.5
      src += src.filter(:highpass, cutoff: 1800, quality: 0.7) * air if air > 0
      morph = v.filter_env(0.06, 0.35, 0.55, 0.2)
      mouth = src.formant(*vowels, morph: morph, shift: (v.number - 62) * 0.25, width: width)
      (mouth * 2).softclip(0.6, 0.95) * v.amp_env(0.01, 0.4, 0.75, 0.12) * 1.05
    }.delay(1.n8.dotted, feedback: 0.25, wet: echo, dry: 1) * (0.75 * level)
  end

  # A soft "ooh" choir: two saws a little apart per note through an alto
  # "u -> o" formant, slow attack, highpassed at 220 Hz.
  def self.funk_choir_voice(midi, level: 0.36)
    synth(midi, voices: 4) { |v|
      f = v.hz.vibrato(4.6, depth: 0.12)
      (f.saw * 0.5 + f.transpose(0.07).saw * 0.5).formant(:u, :o, morph: 0.6, voice: :alto) *
        v.amp_env(0.35, 1.0, 0.8, 0.8) * level
    }.filter(:highpass, cutoff: 220)
  end

  # The audio looper: +sig+ plus a +length+ delay loop that +sig+ goes
  # into while +dub+ (the footswitch; 0 or 1, a number or a node such as a
  # knob) is up, keeping +keep+ (a number or a node) every pass.
  def self.funk_dub_loop(sig, dub: 1, keep: 0.82, length: 4.bars)
    sig + (sig * dub).delay(length, feedback: keep, wet: 1, dry: 0)
  end

  # The script's patches by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  def self.funk_patch(midi, patch = :keys, dub: 0.0, keep: 0.82)
    case patch
    when :beat then funk_beat(midi)
    when :perc then funk_perc(midi)
    when :bass then funk_bass_voice(midi)
    when :keys then funk_keys_voice(midi)
    when :clav then funk_clav_voice(midi)
    when :talkbox then funk_talkbox_voice(midi)
    when :choir then funk_dub_loop(funk_choir_voice(midi), dub: dub.constant.named('dub'), keep: keep.constant.named('keep'))
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  # Where the patches came from, for preset descriptions (--save writes
  # it into the document): +what+ is the patch (a Symbol) or a phrase.
  def self.funk_description(what)
    what = "Funk patch :#{what}" if what.is_a?(Symbol)
    "#{what} from bin/synths/funk.rb, " \
      'first made by Tiko Marvell, a fictional funk / neo-soul live looper, ' \
      'for the set "Loop Church" (bin/songs/loop_church.rb) ' \
      'in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).'
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { funk_description(p.patch) },
      patch: [:keys, Symbol, '-p', 'Patch to play', [:beat, :perc, :bass, :keys, :clav, :talkbox, :choir]],
      dub: [0.0, Float, '-d', 'Choir looper footswitch: 1 records into the loop', 0.0..1.0],
      keep: [0.82, Float, '-k', 'Choir looper feedback per pass 0..1', 0.0..0.99],
    ) { |midi, p|
      funk_patch(midi, p.patch, dub: p.dub, keep: p.keep)
    }
  end
end
