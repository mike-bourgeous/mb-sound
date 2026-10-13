#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Drum & bass patches (Reese, sub, neuro bass, pad, pluck, impact, drums, a
# club master), playable from MIDI.
#
# Where they came from: the persona panel experiment of 2026-10-13
# (research branch research-persona-edm, research/persona-panel/edm/), in
# which a fictional persona, Kez Volta (a modern EDM / UK drum & bass
# producer-DJ), wrote the song "Tunnel Vision" (bin/songs/tunnel_vision.rb)
# with the public API.  The patches moved here so they can be played,
# reused, and saved as presets, named for the genre (patches-2,
# 2026-10-13).
#
# Patches (-p):
#   reese  six detuned saws (unison), a 4-pole lowpass breathing on a 2-bar
#          LFO around --cutoff, softclipped, highpassed at 150 Hz off the sub
#   sub    one sine through a 110 Hz lowpass, gliding between legato notes
#          with a quiet 2nd and 3rd for small speakers (harmonics: false
#          for the bare sine; [0.4, 0.2] is Small Talk's louder pair)
#   neuro  the "switch-up" bass: saws plus a square an octave up into a
#          diode ladder jumping on 16ths, talking formants morphing on 8ths,
#          a key-tracked crusher (--grit wet), squeezed; AM noise and a
#          little hard sync on top (noise: 0.5, sync: 0.2; fold: a
#          wavefolded sine; 0 for none)
#   pad    minor-9th pad: three detuned saws per note, slow swell, hall
#   pluck  liquid pluck: a square through a closing lowpass, a dotted-eighth
#          delay (--send) and a plate
#   boom   the impact: a sine falling two octaves onto the note, into a hall
#   drums  the song's tr808 kit pushed to DnB tunings (GM note map), with
#          parallel compression (tight: true tunes the kick up, shortens
#          and highpasses it, so the sub takes center stage; room: true a
#          gated room on the backbeat; glue: true drum-bus compression)
#
# Every patch is one method taking a MIDI source (Notes, Clip, MIDI file, or
# Stream) and its knobs as keywords: dnb_reese_voice(midi, cutoff:),
# dnb_sub_voice, dnb_neuro_voice(midi, grit:), dnb_pad_voice,
# dnb_pluck_voice(midi, send:), dnb_boom_voice, dnb_drums.  Each is also a
# preset (presets/dnb_*.mbg.rb): `preset :dnb_reese, midi: midi, cutoff: 900`.
#
# Usage:
#     bin/synths/dnb.rb                                   # live MIDI, the Reese
#     bin/synths/dnb.rb -p neuro --grit 0.6 song.mid neuro.flac
#     bin/synths/dnb.rb -p drums spec/test_data/c2_sustain.mid drums.flac
#     MB_SOUND_PRESETS=presets bin/synths/dnb.rb -p reese --save dnb_reese spec/test_data/c_major.mid
#
# Snippets (bin/sound.rb, after `load 'bin/synths/dnb.rb'`):
#     bpm 174
#     riff = seq(F1, T, T, T, T, T, R, F1, T, R, Ab1, T, F1, T, R, R).n16.loop
#     bg :reese, dnb_reese_voice(riff, cutoff: 900)
#     bg :sub, dnb_sub_voice(riff) * 0.5
#     swap :reese, riff.transpose(5)
#     bg :neuro, dnb_neuro_voice(riff, grit: 0.6)            # the switch-up
#     bg :neuro, dnb_neuro_voice(riff, sync: 0.5)            # more screaming sync harmonics (or fold:, noise:)
#     bg :neuro, dnb_neuro_voice(riff, sync: 0, noise: 0)    # the darker neuro before 2026-10-13
#     bg :pad, dnb_pad_voice(seq(F2.n1, Db2.n1).bake(chord(0, 7, 15, 19, 26)).loop) * 0.6
#     bg :drums, dnb_drums(grid(16, kick: 'X.........X.....', snare: '....X.......X...', hat: '7.4.7.4.7.4.7.45').loop)
#     bg :drums, dnb_drums(grid(16, kick: 'X.........X.....', snare: '....X.......X...').loop, room: true, glue: true)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The two-step kick's settings (a Hash for tr808's +kick:+), shared by
  # .dnb_drums and .dnb_ghost_kick so a sidechain ducks to the same kick.
  def self.dnb_kick_settings
    { tune: 54, decay: 0.38, tone: 0.62, sigh: 0.9 }
  end

  # The Reese: six detuned saws (the beating does the moving), a 4-pole
  # lowpass breathing on a 2-bar LFO (+breath+ octaves either side) around
  # +cutoff+ (a number or a node, e.g. a knob), a softclipper, and a
  # highpass at +highpass+ Hz (twice) so it never fights the sub.  Spread a
  # little in stereo by the unison (only above the highpass, so the low end
  # stays mono).  Mono legato with a +glide+ in seconds.
  def self.dnb_reese_voice(midi, cutoff: 2400, detune: 0.32, spread: 0.5, breath: 0.8, drive: 2.2, resonance: 0.25, glide: 0.035, highpass: 150)
    synth(midi, voices: 1) { |v|
      pitch = v.hz.glide(glide, legato: true)
      saws = pitch.unison(6, detune: detune, spread: spread) { |p, _i| p.saw }
      lfo = 2 ** v.lfo(2.bars, shape: :sine, depth: breath)
      amp = v.env(0.004, 0.25, 0.85, 0.06, gm: false).legato
      ((saws.lp4(cutoff * lfo, resonance: resonance) * drive).softclip(0.35, 0.95) * amp)
        .filter(:highpass, cutoff: highpass, quality: 0.7).filter(:highpass, cutoff: highpass, quality: 0.7)
    }
  end

  # The 2nd and 3rd harmonic levels of the sub's harmonics: true: half of
  # Small Talk's [0.4, 0.2] (patches-3, 2026-10-13: "For dnb the harmonic
  # levels should be a bit lower if present").
  DNB_SUB_HARMONICS = [0.2, 0.1].freeze

  # The sub: one sine, mono, lowpassed at +cutoff+ Hz, gliding between
  # legato notes.  +harmonics+ (true, the default, for DNB_SUB_HARMONICS;
  # false for none, the sub before 2026-10-13; or [2nd, 3rd] levels, e.g.
  # [0.4, 0.2] like Small Talk's sub) adds sines
  # at 2x and 3x after the lowpass, phase-locked to the sub, scaled to keep
  # its RMS, so the sub carries on speakers that can't play its
  # fundamental.
  def self.dnb_sub_voice(midi, cutoff: 110, glide: 0.035, harmonics: true)
    harmonics = DNB_SUB_HARMONICS if harmonics == true
    h2, h3 = harmonics || [0, 0]
    unless h2 > 0 || h3 > 0
      return synth(midi, voices: 1) { |v|
        pitch = v.hz.glide(glide, legato: true)
        (pitch.sine * v.env(0.003, 0.3, 0.9, 0.05, gm: false).legato).filter(:lowpass, cutoff: cutoff, quality: 0.7)
      }
    end

    synth(midi, voices: 1) { |v|
      pitch = v.hz.glide(glide, legato: true)
      env = v.env(0.003, 0.3, 0.9, 0.05, gm: false).legato
      upper = pitch.transpose(12).sine * h2 + pitch.transpose(12 * Math.log2(3)).sine * h3
      ((pitch.sine * env).filter(:lowpass, cutoff: cutoff, quality: 0.7) + upper * env) * (1 / Math.sqrt(1 + h2**2 + h3**2))
    }
  end

  # dnb_neuro_voice's default top end (patches-4, 2026-10-13; maintainer
  # on the patches-3 layers, picking noise: 0.5: "Noise with a bit of sync
  # maybe?"); before, every layer was 0 (`sync: 0, noise: 0`).
  DNB_NEURO_TOP = { sync: 0.2, noise: 0.5 }.freeze

  # The neuro switch-up: saws plus a square an octave up into a diode
  # ladder whose cutoff (+cutoff+ Hz, opened two octaves by the note's
  # envelope) jumps on a 16th square LFO, through talking formants that
  # morph on 8th notes, a softclipper, a key-tracked crusher (+grit+ wet;
  # a number or a node), and a squeeze (+squeeze+ depth).  Highpassed off
  # the sub.
  #
  # Three more sources of high end, each a level (0..1, a number or a
  # node; DNB_NEURO_TOP by default: noise 0.5, a little sync, no fold) of
  # a layer added after the formants, so the ladder and the vowels don't
  # darken it (patches-3, 2026-10-13: "Is there some
  # other source of high end available? E.g. harmonics from the
  # oscillator or AM noise?"):
  # +sync+   a hard-synced saw whose ratio sweeps 2..9 times the note
  #          with the envelope and jumps with the 16th LFO (the classic
  #          screaming sync harmonics), band-passed 1.2-14 kHz
  # +fold+   a sine wavefolded (an antialiased mirror fold, #ease) harder
  #          as the envelope and the 16ths open: bright, glassy harmonics
  #          of the note, band-passed 1-14 kHz (above 14 kHz, the layers
  #          made the softclipper's half-sample allpass overshoot by 6 dB)
  # +noise+  noise amplitude-modulated by a pulse train at the note's
  #          pitch (a buzzy, pitched hiss like a hard-driven reed),
  #          highpassed at 3 kHz
  def self.dnb_neuro_voice(midi, grit: 0.25, cutoff: 600, resonance: 0.55, squeeze: 0.7, highpass: 140, sync: DNB_NEURO_TOP[:sync], fold: 0, noise: DNB_NEURO_TOP[:noise])
    synth(midi, voices: 1) { |v|
      pitch = v.hz.glide(0.02, legato: true)
      src = pitch.unison(3, detune: 0.18) { |p, _i| p.saw } + pitch.transpose(12).square * 0.4
      lfo = v.lfo(1.n16, shape: :square, depth: 1.3)
      jump = 2 ** lfo
      env = v.env(0.002, 0.12, 0.6, 0.04, gm: false)
      ladder = src.diode(cutoff * jump * (2 ** (env * 2)), resonance: resonance)
      talk = ladder.formant(:o, :a, :i, voice: :bass, morph: v.lfo(1.n8, shape: :triangle, unipolar: true) * 2)
      # (each layer's level: a little under the talk's RMS at 1)
      unless sync == 0
        ratio = (env * 4 + lfo * 1.5 + 3.5).aclip(2, 9)
        talk += pitch.saw.sync(ratio: ratio).filter(:highpass, cutoff: 1200, quality: 0.7).filter(:lowpass, cutoff: 14000, quality: 0.7) * (sync * 0.8)
      end
      unless fold == 0
        folded = (pitch.sine * (env * 12 + jump * 3 + 2)).ease(:linear, range: -1..1, edges: :mirror)
        talk += folded.filter(:highpass, cutoff: 1000, quality: 0.7).filter(:lowpass, cutoff: 14000, quality: 0.7) * (fold * 2.5)
      end
      unless noise == 0
        buzz = (pitch.pulse(0.3) + 1) * 0.5
        talk += MB::Sound.noise.filter(:highpass, cutoff: 3000, quality: 0.7) * buzz * (noise * 0.3)
      end
      crushed = (talk * 3).softclip(0.3, 0.95).decimate(v.freq * 24, mix: grit)
      crushed * env.legato
    }.squeeze(:default, depth: squeeze, split: [250, 2500]).filter(:highpass, cutoff: highpass, quality: 0.7)
  end

  # Minor 9th pads: three detuned saws per note, slow swell, a lowpass at
  # +cutoff+, highpassed at 200 Hz, a hall (+hall+ wet).  Stereo.
  def self.dnb_pad_voice(midi, cutoff: 2600, hall: 0.35, voices: 10)
    synth(midi, voices: voices) { |v|
      saws = v.hz.unison(3, detune: 0.12) { |p, _i| p.saw }
      (saws.lp4(cutoff, resonance: 0.1) * v.env(0.6, 0.5, 0.8, 1.2, gm: false) * 0.25)
    }.filter(:highpass, cutoff: 200, quality: 0.7).reverb(:hall, mix: hall, output_channels: 2)
  end

  # The liquid pluck: a soft square through a closing lowpass, a
  # dotted-eighth delay (+send+ wet, a number or a node; +feedback+), a
  # plate (+plate+ wet).  Stereo.
  def self.dnb_pluck_voice(midi, send: 0.4, feedback: 0.4, plate: 0.25)
    synth(midi, voices: 2) { |v|
      fenv = v.env(0.001, 0.18, 0.0, 0.1, gm: false)
      tone = v.hz.square.lp4(500 * (2 ** (fenv * 3)), resonance: 0.3)
      tone * v.env(0.002, 0.35, 0.0, 0.15, gm: false) * 0.5
    }.delay(1.n8.dotted, feedback: feedback, wet: send, dry: 1).reverb(:plate, mix: plate, output_channels: 2)
  end

  # The impact: a sine falling +drop+ octaves onto the note in 0.25 s,
  # softclipped, into a hall.  Stereo.
  def self.dnb_boom_voice(midi, drop: 2, level: 0.4)
    synth(midi, voices: 1) { |n|
      dive = n.env(0, 0.25, 0, 0.1, curve: :linear, gm: false)
      ((n.freq * (2 ** (dive * drop))).tone * n.env(0.001, 1.2, 0, 0.3, gm: false) * 1.4).softclip(0.5, 0.95)
    }.reverb(:hall, mix: 0.2, highpass: 200, output_channels: 2) * level
  end

  # The drums: a tr808 kit pushed up to DnB tunings (a two-step kick, a
  # high tight snare, short hats) playing +source+ (a grid Kit, a clip, or
  # MIDI with tr808's GM note map), with parallel compression (+parallel+
  # wet).  Voice settings as tr808 Hashes.
  #
  # +tight+ (true, or a highpass frequency in Hz; true is 65 Hz) makes
  # room for the sub, as a lot of DnB does: the kick is tuned up a fourth
  # (above the sub's notes), decays faster, clicks brighter, and only the
  # kick is highpassed (24 dB/octave), so it is a punch above the sub
  # instead of a boom under it.
  #
  # +room+ (true, or the wet level; true is DNB_DRUMS_ROOM) sends the
  # snare, clap, rimshot, and toms (not the kick or the cymbals) into a
  # gated room (Reverb's :gated, closed +room_gate+ seconds after the
  # hit), so the backbeat gets a short, bright splash that never smears
  # the next hit; the drums are stereo then.  +glue+ (true, or a Hash of
  # #compress options over DNB_DRUMS_GLUE) compresses the whole kit after
  # the parallel compression, as a drum-bus compressor: a few dB of slow
  # attack, fast release pumping that glues the hits together (patches-3,
  # 2026-10-13: "Some gated room reverb and compression would be a nice
  # addon too").  Both default off.
  #
  # The room's gate opens while the sent drums are above +room_threshold+
  # and closes +room_gate+ seconds after they fall below it, in a room
  # decaying over +room_decay+ seconds (RT60), so only the loud backbeat
  # hits splash (ghost snares stay dry) and each splash is gone in about
  # an eighth note at 174 BPM (220 ms after the hit to -40 dB).
  # patches-4 (2026-10-13; maintainer: "Tail is way too long on snare
  # room"): patches-3's room (`room_gate: 0.18, room_threshold: -30.db,
  # room_decay: 2.5`) stayed open about 420 ms, as long as the snare's
  # own tail stayed above -30 dBFS plus the gate.
  def self.dnb_drums(
    source, kick: dnb_kick_settings, snare: { tune: 205, decay: 0.2, snappy: 0.8, tone: 0.8, level: 0.95 },
    hat_decay: 0.035, accent: 6, parallel: 0.35, tight: false, room: false, room_gate: 0.08, glue: false,
    room_threshold: -12.db, room_decay: 1.0
  )
    settings = {
      kick: kick, snare: snare,
      clap: { decay: 0.16, tone: 0.8, level: 0.5 }, rimshot: { level: 0.35 },
      closed_hat: { decay: hat_decay, tone: 0.85, level: 0.55 }, open_hat: { decay: 0.16, tone: 0.7, level: 0.25 },
      cymbal: { decay: 1.4, tone: 0.7, level: 0.3 }, maracas: { level: 0.25 }, low_tom: { tune: 120, decay: 0.35 }, accent: accent
    }
    beat = if tight || room
             if tight
               cut = tight == true ? 65 : tight
               tuned = kick.merge(tune: kick.fetch(:tune, 52) * 2**(5 / 12.0), decay: 0.15, tone: 0.8, level: kick.fetch(:level, 1.0) * 1.6)
               settings = settings.merge(kick: tuned)
             end
             outs = tr808(source, **settings, outputs: :separate)
             parts = outs.names.map { |name|
               tight && name == :kick ? outs[name].filter(:highpass, cutoff: cut, quality: 0.7).filter(:highpass, cutoff: cut, quality: 0.7) : outs[name]
             }
             mixed = GraphNode::Mixer.new(parts, stop_early: false) # (until every voice has ended, like the mixed kit)
             if room
               sent = outs.names.select { |name| DNB_DRUMS_ROOM_SENDS.include?(name) }.map { |name| outs[name] }
               wet = room == true ? DNB_DRUMS_ROOM : room
               splash = GraphNode::Mixer.new(sent, stop_early: false)
                 .reverb(:gated, gate: room_gate, threshold: room_threshold, decay: room_decay, dry: 0, wet: 1, output_channels: 2)
                 .filter(:highpass, cutoff: 250, quality: 0.7)
               # (a sum ends when any of its inputs ends: each waits for the other, as when a MIDI file ends)
               mixed.and_then(silence(2)) + (splash * wet).and_then(silence(2))
             else
               mixed
             end
           else
             tr808(source, **settings)
           end
    beat = beat.compress(threshold: -24.db, ratio: 4, attack: 0.002, release: 0.06, makeup: 9, mix: parallel)
    glue ? beat.compress(**DNB_DRUMS_GLUE, **(glue == true ? {} : glue)) : beat
  end

  # The gated room's wet level for dnb_drums(room: true).
  DNB_DRUMS_ROOM = 0.3

  # The kit voices dnb_drums(room:) sends into its gated room.
  DNB_DRUMS_ROOM_SENDS = [:snare, :clap, :rimshot, :low_tom, :mid_tom, :high_tom].freeze

  # dnb_drums(glue: true)'s drum-bus compressor (#compress options).
  DNB_DRUMS_GLUE = { threshold: -18.db, ratio: 3, knee: 6, attack: 0.01, release: 0.08, makeup: 4 }.freeze

  # A ghost kick for sidechains: the drums' kick alone playing +source+,
  # never heard (duck a bass with it: `bass.duck(dnb_ghost_kick(kit))`).
  def self.dnb_ghost_kick(source, kick: dnb_kick_settings)
    tr808(source, kick: kick)
  end

  # The club master for a mix (a node or bundle): a highpass at +air+
  # (Hz; a number or a node), glue compression, +drive+ dB into a
  # softclipper, and a true-peak limiter at +ceiling+ dBTP (clip, then
  # limit).
  def self.dnb_master(mix, drive: 11.0, ceiling: -0.5, air: 20)
    glued = mix.filter(:highpass, cutoff: air, quality: 0.7)
      .compress(threshold: -14.db, ratio: 2, knee: 6, attack: 0.01, release: 0.12)
    (glued * drive.db).softclip(0.6, 1.0).limit(ceiling: ceiling.db, release: 0.06)
  end

  # The script's patches by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  def self.dnb_patch(midi, patch = :reese, cutoff: 2400.0, grit: 0.25, echo: 0.4)
    case patch
    when :reese then dnb_reese_voice(midi, cutoff: cutoff.constant.named('cutoff'))
    when :sub then dnb_sub_voice(midi)
    when :neuro then dnb_neuro_voice(midi, grit: grit.constant.named('grit'))
    when :pad then dnb_pad_voice(midi)
    when :pluck then dnb_pluck_voice(midi, send: echo.constant.named('echo'))
    when :boom then dnb_boom_voice(midi)
    when :drums then dnb_drums(midi)
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  # Where the patches came from, for preset descriptions (--save writes
  # it into the document): +what+ is the patch (a Symbol) or a phrase.
  def self.dnb_description(what)
    what = "Drum & bass patch :#{what}" if what.is_a?(Symbol)
    "#{what} from bin/synths/dnb.rb, " \
      'first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, ' \
      'for the song "Tunnel Vision" (bin/songs/tunnel_vision.rb) ' \
      'in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).'
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { dnb_description(p.patch) },
      patch: [:reese, Symbol, '-p', 'Patch to play', [:reese, :sub, :neuro, :pad, :pluck, :boom, :drums]],
      cutoff: [2400.0, Float, '-c', 'Reese lowpass center in Hz', 150.0..8000.0],
      grit: [0.25, Float, '-G', 'Neuro crusher wet share 0..1', 0.0..1.0],
      echo: [0.4, Float, '-e', 'Pluck delay send (echo level) 0..1', 0.0..1.0],
    ) { |midi, p|
      dnb_patch(midi, p.patch, cutoff: p.cutoff, grit: p.grit, echo: p.echo)
    }
  end
end
