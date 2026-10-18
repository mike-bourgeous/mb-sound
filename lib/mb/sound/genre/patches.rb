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

        # A house bass (Munro's "one saw with a tempo-set decay"): one saw
        # voice through a four-pole lowpass at +cutoff+ Hz opened +env+
        # octaves by a short filter envelope, a plucked level with no
        # sustain (+decay+ a length: an eighth note by default, so it
        # follows the tempo), a little velocity, and a soft clip.  Mono.
        # (genre-fixes, 2026-10-18: the house template's bass.)
        def house_bass(source, cutoff: 240, env: 2.5, resonance: 0.35, decay: 1.n8, level: 1.0)
          MB::Sound.synth(source, voices: 1) { |v|
            fenv = v.env(0.001, 0.06, 0, 0.04, gm: false)
            amp = v.env(0.002, decay, 0, 0.04, gm: false) * (v.velocity * 0.4 + 0.6)
            (v.hz.saw.lp4(2 ** (fenv * env) * cutoff, resonance: resonance) * amp).softclip(0.7, 0.97)
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
    end
  end
end
