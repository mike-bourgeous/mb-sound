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
