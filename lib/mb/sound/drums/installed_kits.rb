module MB
  module Sound
    module Drums
      # Kits by kind (drum-gen-1, 2026-11-22; the maintainer: use the
      # apt-installed SoundFont kits, a missing font "Fall back with a
      # line"): `kit(:acoustic)` is the first installed SoundFont kit of a
      # list (found by name on Sampler::FontPath's search path), else a
      # synthesized drum machine, saying once which package to install.
      # Each kind is a library entry, `L.kit.acoustic` (family :installed),
      # so a track plays it (`track :drums, kit(:acoustic)`), a generator
      # names it as its kit (`Generators.beat :rock, kit: :acoustic`), and
      # a saved set keeps the kind, never a path.
      #
      #     track :drums, kit(:acoustic)          # Black Pearl if installed, ..., else the 909
      #     bg :drums, L.gen.beat.rock
      #     Drums::InstalledKits.found(:acoustic)  # => ["Black_Pearl_4_LV2", [0, 0]], or nil
      module InstalledKits
        # Kinds: +fonts+ the [font name, preset] candidates in order (the
        # first installed plays), +fallback+ the drum machine played when
        # none is (:tr909 or :tr808), +package+ the Debian package that
        # ships the first fonts, +about+ for listings.
        KINDS = {
          acoustic: {
            fonts: [['Black_Pearl_4_LV2', [0, 0]], ['Red_Zeppelin_4_LV2', [0, 0]], ['FluidR3_GM', [128, 0]], ['TimGM6mb', [128, 0]], ['sf_GMbank', [128, 0]]],
            fallback: :tr909, package: 'avldrums.lv2-soundfont',
            about: 'An acoustic rock and pop kit: Black Pearl or Red Zeppelin, else a GM Standard kit, else the TR-909',
          },
          jazz: {
            fonts: [['Blonde_Bop_HR_LV2', [0, 0]], ['Blonde_Bop_LV2', [0, 0]], ['FluidR3_GM', [128, 32]], ['TimGM6mb', [128, 32]], ['sf_GMbank', [128, 32]]],
            fallback: :tr909, package: 'avldrums.lv2-soundfont',
            about: 'A jazz kit for lo-fi and brushes: Blonde Bop, else a GM Jazz kit, else the TR-909',
          },
          hand_percussion: {
            fonts: [['Buskmans_Holiday_LV2', [0, 0]], ['FluidR3_GM', [128, 0]], ['TimGM6mb', [128, 0]], ['sf_GMbank', [128, 0]]],
            fallback: :tr808, package: 'avldrums.lv2-soundfont',
            about: 'Hand percussion (cajon, congas, shakers): Buskmans Holiday, else a GM kit\'s percussion, else the TR-808\'s congas',
          },
          gm: {
            fonts: [['FluidR3_GM', [128, 0]], ['TimGM6mb', [128, 0]], ['sf_GMbank', [128, 0]]],
            fallback: :tr909, package: 'fluid-soundfont-gm',
            about: 'A General MIDI Standard kit: FluidR3, TimGM6mb, or sf_GMbank, else the TR-909',
          },
        }.freeze

        # Sampler voices a SoundFont kit plays with.
        VOICES = 16

        # The kits' one setting (ux-friction-4, the maintainer's take of
        # 2026-11-21: `L.kit.jazz.tune(-3)` and `.transpose(-3)`, to pitch
        # the kit down without changing which drum a key plays): every
        # drum's pitch in semitones (fractions are cents), the sampler
        # voices' +transpose:+.  A track playing the kit gets it as the
        # knob :"drums/tune" (Arrangement::TrackKnobs; read while the kit
        # builds, so a turn rebuilds the track).  The fallback drum
        # machines keep their pitch (their voices have tune knobs of their
        # own, in Hz).
        TUNE = Param.declare(:tune, 0.0, range: -24.0..24.0, unit: 'semitones',
                             description: 'Pitch of every drum in semitones (which drum each key plays stays)')

        class << self
          # Whether #notice prints (live mode only, once per kind and
          # process; spec_helper turns it off before each example).
          attr_accessor :enabled
        end
        self.enabled = true

        module_function

        # The KINDS entry for +kind+, raising with the kinds for another.
        def kind(kind)
          KINDS.fetch(kind.to_sym) {
            raise ArgumentError, "No kit #{kind.inspect} (kits: #{KINDS.keys.map(&:inspect).join(', ')})#{Library.suggest(kind.to_sym, KINDS.keys)}"
          }
        end

        # [font name, preset] of the first installed font of +kind+, or nil.
        def found(kind)
          kind(kind)[:fonts].each do |name, preset|
            path = Sampler::FontPath.find(name) rescue nil
            next unless path
            font = Sampler::SF2.open(name) rescue next
            next unless (font.preset(preset) rescue nil)
            return [name, preset]
          end
          nil
        end

        # What +kind+ plays: a Sampler::Instrument (the SoundFont kit,
        # printing as `sf2('Black_Pearl_4_LV2', preset: [0, 0])`), or the
        # fallback machine's name (:tr909).
        def instrument(kind)
          name, preset = found(kind)
          return kind(kind)[:fallback] unless name
          MB::Sound.sf2(name, preset: preset)
        end

        # The kit +kind+ playing +source+ (a clip, MIDI source): the
        # SoundFont kit's sampler, else the fallback machine, printing the
        # notice once (see #notice).  +tune+ (semitones: a number, or a
        # param or knob read now; see TUNE) pitches every drum of a
        # SoundFont kit; the machines play at their own pitch, saying so
        # once in the console (#tune_notice).
        def play(kind, source, tune: 0)
          tune = GraphNode.build_value(tune).to_f
          inst = instrument(kind)
          if inst.is_a?(Symbol)
            notice(kind)
            tune_notice(kind, inst) unless tune.zero?
            return MB::Sound.public_send(inst, source)
          end
          tune.zero? ? inst.sampler(source, voices: VOICES) : inst.sampler(source, voices: VOICES, transpose: tune)
        end

        # How to tune kit +kind+ by +tune+ semitones on a track, as words
        # to add to a message ("; tuned: ..."), or '' for a zero tune.
        def tune_hint(kind, tune)
          t = (Float(tune) rescue 0.0)
          return '' if t.zero?
          v = RubyValue.text(t == t.round ? t.round : t)
          "; tuned: track :drums, L.kit.#{kind}, then turn :\"drums/tune\", #{v} (the kit's tune knob), " \
            "or in a patch track(:drums) { |c| L.kit.#{kind}.(c, tune: #{v}) }"
        end

        # The line saying the fallback +machine+ playing +kind+ keeps its
        # pitch, printed once per kind and process in live mode (as
        # #notice).  Returns the message printed, or nil.
        def tune_notice(kind, machine)
          return nil unless enabled && MB::Sound.live?
          key = :"#{kind}/tune"
          first = LOCK.synchronize { (@noticed ||= {}).key?(key) ? false : (@noticed[key] = true) }
          return nil unless first
          msg = "kit(#{kind.to_sym.inspect}): tune pitches SoundFont kits; the #{machine} playing instead keeps its pitch " \
                "(its voices have tune knobs in Hz: #{machine}(clip, kick: { tune: 50 }))"
          warn msg
          msg
        end

        # The line saying +kind+ has no installed font: the package to
        # install and, on a Mac, where to put copied files.
        def message(kind)
          k = kind(kind)
          mac = RUBY_PLATFORM.include?('darwin')
          get = mac ? "copy .sf2 files from #{k[:package]} into ~/Library/Audio/Sounds/Banks (Homebrew has no SoundFont package)" :
                      "apt install #{k[:package]}"
          "kit(#{kind.to_sym.inspect}): no #{kind.to_s.tr('_', ' ')} SoundFont installed (#{get}; MB_SOUND_SOUNDFONTS adds folders); playing #{k[:fallback]}"
        end

        # Prints #message for +kind+ once per process in live mode (the
        # console); never in scripts, renders, or specs.  Returns the
        # message printed, or nil.
        def notice(kind)
          return nil unless enabled && MB::Sound.live?
          first = LOCK.synchronize { (@noticed ||= {}).key?(kind.to_sym) ? false : (@noticed[kind.to_sym] = true) }
          return nil unless first
          msg = message(kind)
          warn msg
          msg
        end

        LOCK = Mutex.new

        # Forgets which kinds printed their notice (specs).
        def reset_notices
          LOCK.synchronize { @noticed = {} }
        end
      end
    end

    Library.index.define_family(:installed, kind: :kit, owner: Drums::InstalledKits,
                                            about: 'Kits by kind: the first installed SoundFont kit, else a drum machine (kit(:acoustic), L.kit.acoustic)',
                                            code: ->(e) { "kit(#{e.name.inspect})" })
    Drums::InstalledKits::KINDS.each do |name, k|
      Library.index.register(Library::Entry.new(
        name: name, kind: :kit, family: :installed, tags: %i[soundfont], about: k[:about],
        params: { tune: Drums::InstalledKits::TUNE },
        location: "lib/mb/sound/drums/installed_kits.rb:#{__LINE__}",
        builder: ->(source = nil, tune: 0, **kw) {
          if source.nil?
            raise ArgumentError, "kit(#{name.inspect}) plays a clip or MIDI source (track :drums, kit(#{name.inspect}))#{Drums::InstalledKits.tune_hint(name, tune)}"
          end
          unless kw.empty?
            raise ArgumentError, "kit(#{name.inspect}) takes tune: only (got #{kw.keys.map { |key| "#{key}:" }.join(', ')})#{Library.suggest(kw.keys.first, [:tune])}"
          end
          Drums::InstalledKits.play(name, source, tune: tune)
        }
      ))
    end
  end
end
