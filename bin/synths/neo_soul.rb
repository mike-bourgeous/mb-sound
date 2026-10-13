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
#             map) half through a formant "mouth"
#   perc      shaker, rim, and congas (GM note map), highpassed
#   bass      a round funk bass: a sine body plus a lowpassed saw opening
#             with velocity; ghost notes are just thumps
#   keys      an FM electric piano: a 1:1 body whose index falls, a 14:1
#             tine bark for hard strikes, auto-pan tremolo
#   clav      a clav-ish stab: a narrow pulse, highpassed and quick
#   talkbox   the lead: a gliding saw and pulse through a vowel opening
#             "o -> a -> e" on every note, delayed vibrato, a
#             dotted-eighth echo
#   choir     a soft "ooh" choir (two saws through an alto formant), with
#             the audio looper behind it: --dub (the footswitch) sends the
#             voice into a 4-bar loop that loses 1 - --keep every pass
#
# Every patch is one method taking a MIDI source (Notes, Clip, MIDI file, or
# Stream) and its knobs as keywords: neo_soul_beat, neo_soul_perc, neo_soul_bass_voice,
# neo_soul_keys_voice, neo_soul_clav_voice, neo_soul_talkbox_voice, neo_soul_choir_voice;
# the looper is the effect neo_soul_dub_loop(sig, dub:, keep:).  Each is also a
# preset (presets/neo_soul_*.mbg.rb): `preset :neo_soul_keys, midi: midi`.
#
# Usage:
#     bin/synths/neo_soul.rb                              # live MIDI, the keys
#     bin/synths/neo_soul.rb -p talkbox song.mid lead.flac
#     bin/synths/neo_soul.rb -p choir --dub 1 --keep 0.9 song.mid choir.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/neo_soul.rb'`):
#     bpm 96
#     bg :keys, neo_soul_keys_voice(seq([F3, A3, C4, E4].map(&:n4).reduce(:&), R.n4, [F3, B3, E4, A4].map(&:n4).reduce(:&), R.n4).loop)
#     bg :bass, neo_soul_bass_voice(seq(D2, R, R, D2, R, R, A2, C3, R, R, D3, R, F2, R, E2, R).n16.loop)
#     bg :lead, neo_soul_talkbox_voice(seq(A4, R, C5, D5, R, R, F5, E5, D5, R, R, C5, A4, R, R, R).n16.swing(0.57).loop)
#     knob :dub, 1; bg :choir, neo_soul_choir_voice(seq([A3, D4, F4].map(&:n1).reduce(:&)).loop).then { |c| neo_soul_dub_loop(c, dub: knob(:dub)) }

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # Mouth drums: a tr808 kit with short, dry voices (kick, snare, closed
  # and open hats) playing +source+ (a grid Kit, a clip, or MIDI), half of
  # it through a formant filter (+mouth+ wet) so it reads as a mouth more
  # than a machine.
  def self.neo_soul_beat(source, mouth: 0.7, dry: 0.55, level: 2.0)
    kit = tr808(source, only: [:kick, :snare, :closed_hat, :open_hat], velocity_curve: :midi,
      kick: { tune: 56, decay: 0.32, tone: 0.25 },
      snare: { tune: 210, decay: 0.16, tone: 0.55, snappy: 0.75 },
      closed_hat: { decay: 0.035, tone: 0.5 },
      open_hat: { decay: 0.22 },
    )
    vowel = kit.formant(:o, :u, morph: 0.4, width: 1.6)
    (kit * dry + vowel * mouth).softclip(0.7, 0.95) * level
  end

  # The overdub percussion: shaker, rim, congas (+source+ as for
  # .neo_soul_beat), highpassed at 180 Hz.
  def self.neo_soul_perc(source, level: 1.2)
    tr808(source, only: [:maracas, :rimshot, :low_conga, :mid_conga], velocity_curve: :midi, maracas: { decay: 0.05 }, rimshot: { tune: 1700 }, low_conga: { tune: 190 }, mid_conga: { tune: 280 })
      .filter(:highpass, cutoff: 180) * level
  end

  # A round funk bass: sine body plus a lowpassed saw that opens with
  # velocity (up to +bite+ Hz above 160), short and punchy; ghost notes are
  # just thumps.
  def self.neo_soul_bass_voice(midi, bite: 1400, level: 0.55)
    synth(midi, voices: 2) { |v|
      f = v.hz
      env = v.amp_env(0.003, 0.5, 0.55, 0.05)
      cut = v.filter_env(0.002, 0.18, 0.15, 0.05) * v.velocity * bite + 160
      ((f.sine * 0.8 + f.saw.lp4(cut, resonance: 0.25) * 0.55) * env)
    }.softclip(0.6, 0.95) * level
  end

  # FM electric piano: a 1:1 body pair whose index falls (+body+), a 14:1
  # tine bark for hard strikes (+tine+), auto-pan at +tremolo+ Hz.
  def self.neo_soul_keys_voice(midi, level: 1, body: 0.25, tine: 0.18, tremolo: 4.5)
    synth(midi, voices: 8, retrigger: :string) { |v|
      body_mod = v.hz.sine.free * v.fm_env(0, 2.0, 0, 0.5) * body
      body_osc = v.hz.sine.free.pm(body_mod)
      tine_mod = v.hz.transpose(Math.log2(14).oct).sine.free * v.fm_env(0, 0.3, 0, 0.1) * v.velocity * tine
      tine_osc = v.hz.sine.free.pm(tine_mod)
      (body_osc + tine_osc * 0.6) * v.amp_env(0.002, 3.0, 0, 0.25) * 0.35
    }.softclip(0.8, 0.95).filter(:highpass, cutoff: 160).pan(tremolo.hz.lfo.at(0.35)) * level
  end

  # A clav-ish stab: a narrow pulse (+width+), highpassed and quick.
  def self.neo_soul_clav_voice(midi, width: 0.2, cutoff: 3500, level: 0.6)
    synth(midi, voices: 4) { |v|
      v.hz.pulse(width).filter(:highpass, cutoff: 400).lp4(cutoff) * v.amp_env(0.001, 0.12, 0, 0.04) * level
    }
  end

  # The talkbox lead: a glided saw and pulse through a vowel that opens
  # "o -> a -> e" on every note (a filter envelope driving the morph),
  # with a delayed vibrato and a dotted-eighth echo (+echo+ wet).
  def self.neo_soul_talkbox_voice(midi, level: 1, echo: 0.22, glide: 0.045)
    synth(midi, voices: 1) { |v|
      f = v.hz.glide(glide).vibrato(5.2, depth: 0.25, delay: 0.25)
      src = f.saw * 0.6 + f.pulse(0.3) * 0.4
      morph = v.filter_env(0.06, 0.35, 0.55, 0.2)
      src.formant(:o, :a, :e, morph: morph, shift: (v.number - 62) * 0.25, width: 1.0) *
        v.amp_env(0.01, 0.4, 0.75, 0.12) * 0.45
    }.delay(1.n8.dotted, feedback: 0.25, wet: echo, dry: 1) * (0.75 * level)
  end

  # A soft "ooh" choir: two saws a little apart per note through an alto
  # "u -> o" formant, slow attack, highpassed at 220 Hz.
  def self.neo_soul_choir_voice(midi, level: 0.36)
    synth(midi, voices: 4) { |v|
      f = v.hz.vibrato(4.6, depth: 0.12)
      (f.saw * 0.5 + f.transpose(0.07).saw * 0.5).formant(:u, :o, morph: 0.6, voice: :alto) *
        v.amp_env(0.35, 1.0, 0.8, 0.8) * level
    }.filter(:highpass, cutoff: 220)
  end

  # The audio looper: +sig+ plus a +length+ delay loop that +sig+ goes
  # into while +dub+ (the footswitch; 0 or 1, a number or a node such as a
  # knob) is up, keeping +keep+ (a number or a node) every pass.
  def self.neo_soul_dub_loop(sig, dub: 1, keep: 0.82, length: 4.bars)
    sig + (sig * dub).delay(length, feedback: keep, wet: 1, dry: 0)
  end

  # The script's patches by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  def self.neo_soul_patch(midi, patch = :keys, dub: 0.0, keep: 0.82)
    case patch
    when :beat then neo_soul_beat(midi)
    when :perc then neo_soul_perc(midi)
    when :bass then neo_soul_bass_voice(midi)
    when :keys then neo_soul_keys_voice(midi)
    when :clav then neo_soul_clav_voice(midi)
    when :talkbox then neo_soul_talkbox_voice(midi)
    when :choir then neo_soul_dub_loop(neo_soul_choir_voice(midi), dub: dub.constant.named('dub'), keep: keep.constant.named('keep'))
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  # Where the patches came from, for preset descriptions (--save writes
  # it into the document): +what+ is the patch (a Symbol) or a phrase.
  def self.neo_soul_description(what)
    what = "Funk / neo-soul patch :#{what}" if what.is_a?(Symbol)
    "#{what} from bin/synths/neo_soul.rb, " \
      'first made by Tiko Marvell, a fictional funk / neo-soul live looper, ' \
      'for the set "Loop Church" (bin/songs/loop_church.rb) ' \
      'in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).'
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { neo_soul_description(p.patch) },
      patch: [:keys, Symbol, '-p', 'Patch to play', [:beat, :perc, :bass, :keys, :clav, :talkbox, :choir]],
      dub: [0.0, Float, '-d', 'Choir looper footswitch: 1 records into the loop', 0.0..1.0],
      keep: [0.82, Float, '-k', 'Choir looper feedback per pass 0..1', 0.0..0.99],
    ) { |midi, p|
      neo_soul_patch(midi, p.patch, dub: p.dub, keep: p.keep)
    }
  end
end
