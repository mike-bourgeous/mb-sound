module MB
  module Sound
    # Console methods for the SQ-80-flavored voice (SQ80::Voice, its patches
    # in SQ80::PATCHES; see design/notes/sq80.md).
    module SQ80Methods
      # An SQ-80-flavored synth (Ensoniq SQ-80 style, all original wave
      # tables): three wavetable oscillators (a formant wave, a SYNTH 3-style
      # and a PRIME-style table) into a driven four-pole lowpass, SQ-80
      # panel-unit envelopes (sq80_env) on the filter and VCA, a delayed
      # vibrato, a 32nd-note filter chop, and per-key poly pressure flutter.
      # Returns a Synth graph.
      #
      # +source+ is any MIDI source (a clip, Notes, file name; nil: live
      # `midi`), +patch+ a patch name (sq80_patches lists them; :classic is
      # the defaults); either may come first.  +settings+ change the patch
      # (see SQ80::Voice): voices, cutoff (Hz), reso (0..1), drive_mode
      # (:feedback, :input), drive, chop (octaves, 0 off), flutter (octaves
      # per unit of poly pressure, 0 off), second_release (true/false),
      # osc1..osc3 ({ wave:, semitones:, level:, vibrato:, env1: }), env1,
      # env2, env4 (sq80_env panel values: times 0..63, levels -63..63),
      # lfo1 ({ rate:, depth:, delay:, wheel:, pressure: }), filter
      # ({ env2:, key:, velocity:, aftertouch: } octaves), level.  Hash
      # settings change only the keys given.  +seed+ seeds the flutter.
      #
      # Examples (bin/sound.rb):
      #     play sq80                                         # live keyboard (poly pressure shines)
      #     play sq80(:flutter_pad)
      #     bg :sq, sq80(seq(C4, E4, G4, B4).n8.loop, :chop, cutoff: 400)
      #     bg :sq, sq80((seq(C3).n1 & seq(G3).n1 & seq(E4).n1).loop, :glass, env4: { t4: 50 })
      def sq80(source = nil, patch = nil, seed: nil, **settings)
        source, patch = patch, source if source.is_a?(Symbol) || source.is_a?(SQ80::Patch)
        base = case patch
               when nil then {}
               when SQ80::Patch then patch.settings
               else SQ80.patch(patch).settings
               end

        SQ80::Voice.build(source, seed: seed, **SQ80::Voice.merge(base, settings))
      end

      # Lists the SQ-80 voice patches (name and description) and returns
      # their names.  Each is also a preset: `preset :sq80_chop, midi: m`.
      def sq80_patches
        SQ80::PATCHES.each_value do |p|
          puts format('  %-13s %s', p.name.inspect, p.description)
        end
        SQ80.patch_names
      end
    end
  end
end
