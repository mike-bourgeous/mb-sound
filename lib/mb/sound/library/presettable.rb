module MB
  module Sound
    # Named presets for a class or module with settings (the library's
    # "A: class DSL line", maintainer 2026-10-24): `extend Presettable`,
    # declare the family once, then one `preset` line per preset.  Each
    # line makes a frozen Library::Entry registered in Library.index (an
    # error if a shipped name repeats), so presets are found by name, by
    # #find, and under the heads (L.fx.reverb.hall); library files on the
    # shelves add presets of the same family with the same line
    # (`reverb :plate2, decay: 3`, see Library::FileLoader), and lookups
    # (#preset_entry) search the shelves first.
    #
    #     class Reverb
    #       extend Presettable
    #       preset_family :reverb, kind: :effect, apply: ->(name, sig, **o) { sig.reverb(name, **o) }
    #       param :decay, 2.0, range: 0.1..60.0, unit: 's', description: 'RT60 in seconds'
    #       preset :hall, room_size: 0.8, decay: 2.4, tags: %i[big], about: 'Classic hall'
    #     end
    #     Reverb.preset_settings(:hall)    # => { room_size: 0.8, decay: 2.4 }
    #
    # Subclasses inherit their parent's family and params (and may declare
    # params of their own).
    module Presettable
      # Declares the family of this class's presets: +name+ (the verb of
      # library files and the family word under the heads), +kind+ (see
      # Library::KINDS), +label+ (for errors: "Unknown chorus mode :x"),
      # +about+, +apply+ (called with the preset's name and Entry#call's
      # arguments: how a preset is used), +code+ (a Proc printing an
      # entry's code form), and +keys+ (the settings a preset may give, or
      # nil for any; library files are checked against it).
      def preset_family(name, kind:, label: nil, about: nil, apply: nil, code: nil, keys: nil)
        @preset_family = name
        @preset_label = label || "#{name} preset"
        @preset_keys = keys&.map(&:to_sym)&.freeze
        Library.index.define_family(name, kind: kind, about: about, owner: self, apply: apply, code: code)
      end

      # The family name (inherited), or nil.
      def preset_family_name
        return @preset_family if instance_variable_defined?(:@preset_family) && @preset_family
        respond_to?(:superclass) && superclass.respond_to?(:preset_family_name) ? superclass.preset_family_name : nil
      end

      # Settings keys a preset of this family may give (nil: any).
      def preset_keys
        return @preset_keys if instance_variable_defined?(:@preset_keys)
        respond_to?(:superclass) && superclass.respond_to?(:preset_keys) ? superclass.preset_keys : nil
      end

      # Declares a setting's Param (see MB::Sound::Param.declare): presets'
      # entries carry these params with the preset's values as defaults.
      # (Declarations are made when first read: while mb-sound loads, unit
      # values like 2400.hz may not exist yet.)
      def param(name, default = nil, **options)
        (@preset_param_lines ||= {})[name.to_sym] = [default, options]
        @preset_params = nil
      end

      # The declared Params by name (a parent's first).
      def preset_params
        own = instance_variable_defined?(:@preset_params) && @preset_params
        own ||= (@preset_params = (instance_variable_defined?(:@preset_param_lines) ? @preset_param_lines : {}).to_h { |n, (d, o)|
          [n, MB::Sound::Param.declare(n, d, **o)]
        }.freeze)
        up = respond_to?(:superclass) && superclass.respond_to?(:preset_params) ? superclass.preset_params : {}
        up.merge(own)
      end

      # Declares preset +name+ with +settings+ (the class's own keywords),
      # +tags:+ (adjectives and roles), +about:+ (one line), +aliases:+
      # (other names lookups accept), +facets:+ (reserved).  Returns the
      # Library::Entry.
      def preset(name, about: nil, tags: [], facets: {}, aliases: [], **settings)
        family = preset_family_name
        raise ArgumentError, "#{self}: declare the preset family first (preset_family :name, kind: ...)" unless family
        check_preset_keys(name, settings)
        loc = caller_locations(1, 1)[0]
        entry = Library::Entry.new(
          name: name, kind: Library.families.fetch(family).kind, family: family, tags: tags, facets: facets, about: about,
          params: -> { Library::PresetHelpers.params_for(preset_params, settings) }, shelf: Library.builtin_shelf,
          location: "#{loc.path.delete_prefix(File.expand_path('../../..', __dir__) + '/')}:#{loc.lineno}",
          settings: settings, builder: Library::PresetHelpers.builder(family, name)
        )
        Library.index.register(entry)
        aliases.each { |a| Library.index.add_alias(family, a, name) }
        entry
      end

      # Makes +alias_name+ another name for preset +name+ (lookups only).
      def preset_alias(alias_name, name)
        Library.index.add_alias(preset_family_name, alias_name, name)
      end

      # Other names lookups accept ({ alias => preset name }).
      def preset_aliases
        Library.index.aliases(preset_family_name)
      end

      # The presets of this family by name ({ name => Entry }, the first
      # in search order of each name: library files on the shelves before
      # the class's own lines).
      def presets
        Library.index.entries(family: preset_family_name, documents: false).to_h { |e| [e.name, e] }
      end

      # The preset names.
      def preset_names
        presets.keys
      end

      # True if +name+ names a preset (or an alias of one).
      def preset?(name)
        (name.is_a?(Symbol) || name.is_a?(String)) && !Library.index.lookup(preset_family_name, name, note: false).nil?
      end

      # The Entry of preset +name+ (or an alias), raising ArgumentError with
      # suggestions for unknown names.
      def preset_entry(name)
        Library.index.fetch(preset_family_name, name, label: @preset_label || "#{preset_family_name} preset")
      end

      # The settings Hash of preset +name+ (frozen).
      def preset_settings(name)
        preset_entry(name).settings
      end

      # The declarations are private: lines in the class body (`preset
      # :hall, ...`), never calls from outside (`Reverb.preset(:hall)`
      # would declare instead of look up; use .preset_entry).
      private :preset_family, :param, :preset, :preset_alias

      private

      def check_preset_keys(name, settings)
        keys = preset_keys
        return unless keys
        bad = settings.keys - keys
        return if bad.empty?
        raise ArgumentError, "#{preset_family_name} #{name.inspect}: unknown setting#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')}#{Library.suggest(bad[0], keys)}"
      end
    end

    module Library
      # Helpers of Presettable (kept off the classes that extend it).
      module PresetHelpers
        module_function

        # Entry#call for a family preset: the family's apply with the name.
        def builder(family, name)
          ->(*args, **kwargs, &block) {
            apply = Library.families.fetch(family).apply
            raise ArgumentError, "#{family} presets are used by name (#{family}(#{name.inspect}))" unless apply
            apply.call(name, *args, **kwargs, &block)
          }
        end

        # +params+ ({ name => Param }) with the defaults +settings+ give
        # (where they fit the declaration; the rest keep theirs).
        def params_for(params, settings)
          params.to_h { |n, p|
            next [n, p] unless settings.key?(n)
            v = settings[n]
            begin
              [n, MB::Sound::Param.declare(n, v, range: p.implied ? nil : p.range, curve: p.curve == p.default_curve ? nil : p.curve,
                                                  unit: p.unit, description: p.description, type: p.type == :number ? nil : (Param.type_of(v) == :number ? p.type : nil))]
            rescue ArgumentError, MB::Sound::Param::Error
              [n, p]
            end
          }
        end
      end
    end
  end
end
