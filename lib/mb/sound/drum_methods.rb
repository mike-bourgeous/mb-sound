module MB
  module Sound
    # Drum machine kits for the console and scripts (see MB::Sound::Drums).
    # Included in MB::Sound.
    module DrumMethods
      # A TR-808-flavored drum kit (a Drums::Kit node) played by +source+: a
      # grid Kit (rows play the voices they name), or any MIDI source (a
      # clip, `midi`, a MIDI file, a Stream; GM drum notes are routed to the
      # voices).  Per-voice knobs go in Hashes by voice name; see
      # Drums::TR808.kit and Drums::TR808 for every voice and knob.
      # +outputs: :separate+ gives one named channel per voice instead of
      # the mix (see Drums::TR808.kit).
      #
      # Voices: kick, snare, rimshot, clap, closed_hat (hat), open_hat,
      # cymbal, cowbell, low/mid/high_tom, low/mid/high_conga, claves,
      # maracas.  Knobs: tune (Hz), decay (s), tone (0..1), snappy (0..1,
      # snare and toms), level, and sigh (kick).  In grids, X is an
      # accent (+:accent+ dB louder than x, 6 by default); MIDI files and
      # live MIDI play velocity 127 +:accent+ dB louder than 64 (about
      # linear velocity at 6 dB; see Drums.accented).
      #
      # Examples (bin/sound.rb):
      #     bg :drums, tr808(grid(16, kick: 'X..x..x...x.x...', snare: '....X.......X...', hat: 'x.xXx.x.x.xXx.x.').loop)
      #     bg :drums, tr808(grid(16, kick: 'x...x...', cowbell: '..x.xX.x').loop, kick: { tune: 45, decay: 1.2 }, more_cowbell: true)
      #     bg :pads, tr808(midi)                       # play the kit from a MIDI drum pad (GM notes)
      #     bg :file, tr808('drums.mid')               # or a drum track
      #     play tr808(grid(16, kick: 'x...').loop, kick: { tune: 4.bars.lfo.at(45..60) })   # moving knobs
      #     outs = tr808(grid(16, kick: 'x...x...', snare: '....x...').loop, outputs: :separate)
      #     bg :drums, outs[:kick].softclip(0.5) + outs[:snare].reverb(:room)   # individual outputs
      def tr808(source, **settings)
        Drums::TR808.kit(source, **settings)
      end
    end
  end
end
