#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# An FM electric piano in the DX tradition: a "body" operator pair (1:1)
# and a "tine" pair (a 14:1 modulator at a low index that dies away fast),
# with velocity driving brightness and level, and a gentle stereo tremolo.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Re-struck notes behave like a struck string (Synth retrigger: :string): a
# key keeps its voice, and a new strike adds its energy to what's still
# ringing (at most +3 dB over one strike), so soft repeated notes lift the
# ring a little instead of dropping it or doubling it.  The oscillators run
# free (.free), since a re-struck string keeps its phase.  --retrigger picks
# another mode (e.g. reuse, the old drop-to-the-new-peak behavior) to
# compare.  Re-strikes only meet a ringing note while the sustain pedal is
# down, when a key is played again before its release ends, or with a long
# --release (weak dampers).
#
# CC 1 (the mod wheel) adds tine brightness.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid epiano.flac
#     $0 --retrigger reuse spec/test_data/note_velocity.mid
#     $0 --tremolo 0 spec/test_data/c_major.mid   # no tremolo, mono
#     $0 --release 3 spec/test_data/note_velocity.mid  # notes ring into re-strikes

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script(
  retrigger: [:string, Symbol, '-r', 'Same-note retrigger mode', MB::Sound::Synth::RETRIGGER_MODES],
  voices: [8, Integer, '-v', 'Number of voices', 1..32],
  tremolo: [0.35, Float, '-t', 'Stereo tremolo depth (0 for mono)', 0.0..1.0],
  rate: [4.5, Float, 'Stereo tremolo rate in Hz', 0.1..20.0],
  release: [0.35, Float, '-R', 'Release time after the key (and pedal) lifts, in seconds (longer = weaker dampers)', 0.01..10.0],
) { |midi, p|
  s = midi.synth(voices: p.voices, retrigger: p.retrigger) { |v|
    # Body: a 1:1 pair whose index falls over a couple of seconds (warm
    # attack settling to a near-sine), deeper for harder notes
    body_env = v.fm_env(0, 2.5, 0, 0.5).named('Body index envelope')
    body_mod = (v.hz.sine.free * body_env * 1.4).named('Body modulator')
    body = v.hz.sine.free.pm(body_mod).named('Body')

    # Tine: a 14:1 modulator at a low index, gone in a fraction of a second,
    # for the metallic "bark" of a hard strike; the mod wheel adds more
    tine_env = v.fm_env(0, 0.35, 0, 0.1).named('Tine index envelope')
    tine_depth = v.cc(1, range: 0.4..1.6, default: 0, name: 'Tine brightness')
    tine_mod = (v.hz.transpose(Math.log2(14).oct).sine.free * tine_env * tine_depth * v.velocity).named('Tine modulator')
    tine = v.hz.sine.free.pm(tine_mod).named('Tine')

    amp = v.amp_env(0.002, 3.5, 0, p.release, curve: [12, 40, 40]).named('Amplitude')
    ((body + tine * 0.35) * amp * 0.4).named('Voice')
  }

  out = s.softclip(0.8, 0.95)
  next out if p.tremolo == 0

  # A suspended-style stereo tremolo: one panner swept by a slow sine
  out.pan(p.rate.hz.lfo.at(p.tremolo))
}
