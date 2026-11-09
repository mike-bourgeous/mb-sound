module MB
  module Sound
    # Cinematic booms (boom-1, 2026-11-09; see Boom and
    # design/notes/library.md, Booms).  MB::Sound extends itself with this
    # module.
    module BoomMethods
      # A boom instrument (Boom) playing +source+: every note strikes one
      # boom of preset +name+ (:cinematic by default; Boom.preset_names)
      # landing on the note, as hard as its velocity.  +source+ is a Clip,
      # Notes, MIDI file or stream (nil for live MIDI), or a pitch (a Note
      # or MIDI number) for one hit.  Settings override the preset's (see
      # Boom's params: drop, sweep, decay, sub, click, tail, ...; numbers
      # or nodes such as knobs).  +seed+ seeds the click and noise (drawn
      # when nil).  Alias #cinematic_boom.
      #
      #     play boom(G1)                                   # one hit
      #     play boom(:trailer, E1)                         # one hit of a preset
      #     play boom(seq(G1, R, R, R).n1.loop, :impact)    # a hit every 4 bars
      #     track :fx, seq(G1, R, R, R).n1.loop, L.inst.boom.cinematic
      #     play boom(G1, :sub_drop, sweep: 2)              # a slower drop
      def boom(source = nil, name = :cinematic, seed: nil, **settings)
        source, name = name, source if source.is_a?(Symbol)
        name = :cinematic if name.nil?
        source = Boom.strike_clip(name, source) if source.is_a?(Note) || source.is_a?(Integer)
        source ||= midi
        Boom.build(source, name, seed: seed, **settings)
      end
      alias cinematic_boom boom
    end
  end
end
