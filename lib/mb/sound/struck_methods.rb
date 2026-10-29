module MB
  module Sound
    # Struck instruments (library-instruments-1, 2026-10-28; see Struck and
    # design/notes/library.md, Struck instruments): the resonator presets
    # (`sig.resonate(:bar)`, L.fx.bar) played from notes.  MB::Sound
    # extends itself with this module.
    module StruckMethods
      # A struck instrument playing +source+ (a Clip, Notes, MIDI file or
      # stream; nil for live MIDI): every note strikes the modes of the
      # struck preset +name+ (Struck: one per resonator preset, by
      # reference, so `struck(clip, :bar)` rings L.fx.bar's modes; or a
      # library file's `struck :my_bell, resonator: :bell, decay: 8`) at
      # the note's pitch, as hard as its velocity.  +decay+ (seconds, a
      # number or a node such as a knob), +beat+ (Hz), +spread+ (stereo
      # width 0..1, or nil for mono), +voices+, and +level+ override the
      # preset's.  A track playing one gets its decay as a knob
      # (`track :bells, L.inst.bell` makes :"bells/decay").
      #
      #     play struck(seq(C5, E5, G5, C6).n8, :marimba)
      #     track :bells, L.inst.bell
      #     L.fx.bar.ping(C5)                 # one strike of the bar
      #     L.inst.bowl.(riff, decay: 8)      # a shorter bowl
      def struck(source = nil, name = :bar, decay: nil, beat: nil, spread: nil, voices: nil, level: nil)
        source, name = name, source if source.is_a?(Symbol)
        source ||= midi
        Struck.build(source, name, decay: decay, beat: beat, spread: spread, voices: voices, level: level)
      end
    end
  end
end
