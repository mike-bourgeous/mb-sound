module MB
  module Sound
    # Struck instruments (library-instruments-1, 2026-10-28; the
    # maintainer: "make it easy to ping resonant effects as instruments
    # and/or create instruments that reference the resonator effect
    # presets"; design/notes/library.md, Struck instruments).
    #
    # Each resonator effect preset (ModalResonator: bowl, rin, gong, bell,
    # chime, tubular, bar, marimba, vibes, glass, plate, membrane) has a
    # struck instrument of the same name under L.inst (family :struck),
    # built from the resonator preset by reference: `struck(clip, :bar)`
    # strikes `resonate(:bar, note)` once per note, as hard as its
    # velocity, so changing the resonator preset (or shadowing it on a
    # shelf) changes the instrument.  Library files make more with a
    # family line naming the resonator they strike:
    #
    #     struck :my_bell, resonator: :bell, decay: 8, beat: 0.5, tags: %i[soft]
    #
    # and a resonator effect entry pings: `play L.fx.bar` (its demo
    # strike), `L.fx.bar.ping(C5)`, `L.fx.bar.ping(C4, E4, G4)` (a chord).
    module Struck
      extend Presettable
      preset_family :struck, kind: :instrument, label: 'struck instrument', keys: %i[resonator decay beat spread voices level],
        about: 'Resonator presets struck by notes: struck(clip, :bar), L.inst.bar.(clip)',
        apply: ->(name, source = nil, **o) { MB::Sound.struck(source, name, **o) },
        code: ->(e) { "struck(midi, #{e.name.inspect})" }

      param :decay, 8.0, range: 0.05..60.0, description: 'Ring time in seconds (the resonator preset\'s decay)'
      param :beat, 0.0, range: 0.0..10.0, description: 'Doublet beating in Hz (the resonator preset\'s beat)'
      param :voices, 8, range: 1..32, description: 'Notes that ring at once'

      # Voices of a struck instrument (long rings: more than a synth's 4).
      VOICES = 8

      # Output levels by struck preset, for about -20.3 LUFS through the
      # default master on Struck.phrase (the library's instrument
      # convention), from a 4-bar loop of it at 100 BPM, default
      # velocities (spec/lib/mb/sound/struck_spec.rb checks them within
      # 1 LU).  The membrane, a drum, peaks first: its level keeps the peak
      # at -2 dBFS (about -27 LUFS).
      LEVELS = {
        bowl: 0.467, rin: 0.395, gong: 1.142, bell: 1.136, chime: 0.492, tubular: 0.764,
        bar: 0.738, marimba: 1.028, vibes: 0.512, glass: 0.592, plate: 1.492, membrane: 1.39,
      }.freeze

      # Struck params a track turns into knobs (Arrangement::TrackKnobs):
      # the ones resonate reads as nodes (beat and voices are build-time
      # numbers).
      KNOB_PARAMS = %i[decay].freeze

      module_function

      # Registers a struck preset for every resonator preset (by reference:
      # settings name the resonator only).
      def register_resonators!
        GraphNode::ModalResonator.presets.each_value do |res|
          next unless res.shelf.shipped?
          Library.index.register(Library::Entry.new(
            name: res.name, kind: :instrument, family: :struck, tags: res.tags, about: "The #{res.name} resonator (L.fx.#{res.name}) struck by notes: pitch from the note, velocity the strike",
            params: -> { Struck.params_of(res.name) }, settings: { resonator: res.name }, location: res.location,
            builder: Library::PresetHelpers.builder(:struck, res.name)
          ))
        end
        GraphNode::ModalResonator.preset_aliases.each { |a, n| Library.index.add_alias(:struck, a, n) }
      end

      # The params of struck preset +name+: decay and beat at its
      # resonator's values (read now: the resonator preset is the source),
      # voices.
      def params_of(name)
        s = preset_settings(name)
        rs = resonator_preset(s)
        decl = preset_params
        {
          decay: Param.declare(:decay, (s[:decay] || rs.decay).to_f, range: decl[:decay].range, description: decl[:decay].description),
          beat: Param.declare(:beat, (s[:beat] || rs.beat).to_f, range: decl[:beat].range, description: decl[:beat].description),
          voices: Param.declare(:voices, Integer(s[:voices] || VOICES), range: decl[:voices].range, description: decl[:voices].description),
        }
      end

      # The ModalResonator::Preset a struck preset's settings strike.
      def resonator_preset(settings)
        GraphNode::ModalResonator.from_preset(settings[:resonator] || :bowl)
      end

      # The struck instrument (see StruckMethods#struck).
      def build(source, name, decay: nil, beat: nil, spread: nil, voices: nil, level: nil)
        e = preset_entry(name)
        s = e.settings
        res = s[:resonator] || e.name
        opts = { decay: decay || s[:decay], beat: beat || s[:beat], spread: spread || s[:spread] }.compact
        gain = level || s[:level] || LEVELS.fetch(e.name) { LEVELS.fetch(res, 1.0) } # (a library file's struck preset: its resonator's level)
        out = MB::Sound.synth(source, voices: voices || s[:voices] || VOICES) { |v| v.trigger.resonate(res, v.freq, **opts) }
        gain == 1 ? out : out * gain
      end

      # The note nearest +name+'s resonator pitch (a struck preset or a
      # resonator; its typical pitch, e.g. bar 1760 Hz: A6).
      def home_note(name)
        f = resonator_preset(preset_settings(name)).pitch.to_f
        Note.new((69 + 12 * Math.log2(f / 440.0)).round)
      end

      # A short phrase for struck preset +name+: a C major arpeggio and
      # chord moved by octaves toward the preset's typical pitch (two
      # octaves at most either way), as Playable's demo phrase.
      def phrase(name)
        shift = (((home_note(name).number - 60) / 12.0).round).clamp(-2, 2) * 12
        Playable.demo_phrase.transpose(shift)
      end

      # A one-shot clip striking +pitches+ together (Notes or numbers),
      # or the preset's home note.
      def strike_clip(name, pitches)
        notes = pitches.empty? ? [home_note(name)] : pitches.map { |p| p.is_a?(Numeric) ? Note.new(p) : p }
        MB::Sound.seq(notes.length == 1 ? notes[0] : notes).n4
      end

      # The struck preset for library Entry +entry+ (a :struck entry, or a
      # resonator effect's twin), or nil.
      def entry_for(entry)
        return entry if entry.family == :struck
        return nil unless entry.family == :resonator
        Library.index.lookup(:struck, entry.name, note: false)
      end

      # A graph striking +pitches+ once on +entry+'s struck instrument (see
      # Library::Entry#ping).
      def ping(entry, pitches)
        e = entry_for(entry) or raise ArgumentError, "#{entry.head_path} isn't a resonator: ping strikes resonators (L.fx.bar.ping(C5)); `play #{entry.head_path}` plays a demo"
        MB::Sound.struck(strike_clip(e.name, pitches), e.name)
      end
    end
  end
end

MB::Sound::Struck.register_resonators!
