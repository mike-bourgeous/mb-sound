module MB
  module Sound
    module Drums
      # Drum roles and per-kit drum maps (drum-gen-1, 2026-11-22; the
      # maintainer's drum generators decisions): generators write drum
      # ROLES (`kick`, `hat`, `high_tom`, `half_open_hat`, ...: the GM
      # drum names of Sequence::Grid::GM_DRUMS plus the acoustic kits'
      # articulations in Sequence::Grid::EXTENDED_DRUMS, each on its own
      # key), and each kit maps the roles to the keys it has:
      #
      # - a GM drum bank plays GM roles on their own keys,
      # - a kit with a LAYOUTS entry (recognized by its preset or file name,
      #   or by its key set) plays the keys the layout gives, and never the
      #   GM role on a key the layout uses for something else (the
      #   acoustic SoundFont kits' key 50 is a crash choke, not GM's high
      #   tom),
      # - a role the kit lacks plays its FALLBACK (one fixed chain for
      #   every kit: half-open hat, then open hat; high tom, then mid, then
      #   low; ride bell, then ride), or nothing.
      #
      # Only note numbers are kept here (what each kit's key plays, by
      # role); nothing is read from or copied out of any font.
      #
      #     Drums::Roles.note(:half_open_hat)              # => 100
      #     map = Drums::Roles.map(keys: 35..61, layout: :acoustic_kit)
      #     map.key(:high_tom)                              # => 45 (the rack tom)
      #     map.remap                                       # => { 50 => 45, 100 => 46, ... }
      module Roles
        # Every role and the key a generator writes for it (GM names first;
        # aliases of one key, like hat and closed_hat, are one role).
        NOTES = Sequence::Grid::GM_DRUMS.merge(Sequence::Grid::EXTENDED_DRUMS).freeze

        # Role names by key (the first name of each key).
        NAMES = NOTES.each_with_object({}) { |(k, n), h| h[n] ||= k }.freeze

        # Every name of each key ({ 42 => [:closed_hat, :hat] }).
        ALIASES = NOTES.group_by(&:last).transform_values { |l| l.map(&:first).freeze }.freeze

        # What a role plays on a kit that lacks it: the next role to try,
        # in one table for every kit (the maintainer's "one fixed fallback
        # chain").  Roles not listed have no fallback (chokes: a choke
        # played as a hit would be wrong).
        FALLBACK = {
          half_open_hat: :open_hat, open_hat: :closed_hat, hat_swish: :half_open_hat, pedal_hat: :closed_hat,
          high_tom: :high_mid_tom, high_mid_tom: :mid_tom, mid_tom: :low_tom, low_tom: :low_floor_tom,
          high_floor_tom: :low_floor_tom, low_floor_tom: :low_tom,
          rack_tom_edge: :mid_tom, floor_tom_edge: :high_floor_tom,
          ride_bell: :ride, ride_shank: :ride, ride2: :ride,
          crash2: :crash, crash3: :crash2, china: :crash2, splash: :crash,
          electric_snare: :snare, clap: :snare, rimshot: :snare,
          tambourine: :shaker, cabasa: :shaker, shaker: :closed_hat,
        }.freeze

        # Kit layouts other than GM by name: +match+ (a Regexp for a font
        # preset's or file's name), +keys+ (a key set that identifies the
        # layout when the name doesn't: its lowest and highest keys and keys
        # it must have), and +map+ (role => key; a key listed here plays only
        # the roles mapped to it).  Note numbers only.
        LAYOUTS = {
          # The acoustic SoundFont kits of avldrums.lv2-soundfont (Black
          # Pearl, Red Zeppelin, Blonde Bop): a four-piece kit with rack
          # and floor toms (center and rim), hats closed, pedal, semi-open,
          # and swish, three crashes with chokes, a ride with bell, shank,
          # and choke
          acoustic_kit: {
            match: /black.?pearl|red.?zeppelin|blonde.?bop/i,
            keys: { low: 35, high: 61, has: [48, 50, 58, 59, 60] },
            map: {
              kick: 36, rimshot: 37, snare: 38, clap: 39, electric_snare: 40,
              low_floor_tom: 41, closed_hat: 42, high_floor_tom: 43, floor_tom_edge: 43, pedal_hat: 44,
              low_tom: 45, high_tom: 45, open_hat: 46, half_open_hat: 46,
              mid_tom: 47, high_mid_tom: 47, rack_tom_edge: 47, hat_swish: 48,
              crash: 49, crash_choke: 50, ride: 51, ride_choke: 52, ride_bell: 53,
              tambourine: 54, splash: 55, cowbell: 56, crash2: 57, crash2_choke: 58,
              ride_shank: 59, crash3: 60, shaker: 61,
            },
          },
          # Hand percussion (avldrums.lv2-soundfont's Buskmans Holiday): a
          # cajon for kick and snare, congas, shakers and tambourines,
          # claves, a cymbal and its bell, a cowbell
          hand_percussion: {
            match: /buskman/i,
            keys: nil,
            map: {
              kick: 36, rimshot: 37, snare: 38, clap: 39, electric_snare: 40,
              low_conga: 41, closed_hat: 42, shaker: 42, low_floor_tom: 41, high_floor_tom: 43,
              tambourine: 44, mute_high_conga: 47, open_high_conga: 45, low_tom: 45, mid_tom: 47,
              open_hat: 46, half_open_hat: 46, claves: 48, crash: 49, ride: 49, ride_bell: 50, cowbell: 51,
            },
          },
        }.freeze

        # Keys of one-key regions that make a SoundFont preset outside bank
        # 128 a kit Roles may recognize by its key set (a melodic preset
        # spans keys with few regions).
        KIT_KEYS = 10

        module_function

        # The key a generator writes for +role+ (a Symbol), or nil.
        def note(role)
          NOTES[role.to_sym]
        end

        # The roles +role+ falls back to, in order (not itself).
        def chain(role)
          out = []
          r = FALLBACK[role.to_sym]
          while r && r != role.to_sym && !out.include?(r)
            out << r
            r = FALLBACK[r]
          end
          out
        end

        # The LAYOUTS name for a kit called +name+ (a preset or file name)
        # with keys +keys+ (an Enumerable of key numbers), or nil (a GM or
        # unknown layout).
        def layout_for(name: nil, keys: nil)
          LAYOUTS.each { |k, l| return k if name && l[:match].match?(name.to_s) }
          return nil unless keys
          set = keys.to_a
          LAYOUTS.each do |k, l|
            sig = l[:keys] or next
            return k if set.min.to_i >= sig[:low] && set.max.to_i <= sig[:high] && (sig[:has] - set).empty?
          end
          nil
        end

        # A Map for a kit whose keys are +keys+ (Enumerable) with +layout+
        # (a LAYOUTS name, or nil for GM).
        def map(keys:, layout: nil)
          Map.new(keys.to_a.uniq.sort.freeze, layout)
        end

        # +gm_map+ ({ voice => [GM keys] }, a drum machine's routing,
        # TR808::GM_MAP) with the keys of the roles it lacks added to the
        # voice their fallback reaches (the 909's closed hat for a
        # tambourine, its open hat for a half-open hat), so a machine plays
        # every role it can.
        def extend_gm_map(gm_map)
          keys = gm_map.values.flatten
          m = map(keys: keys)
          voice_of = gm_map.flat_map { |v, ns| ns.map { |n| [n, v] } }.to_h
          extra = Hash.new { |h, k| h[k] = [] }
          NAMES.each_key do |n|
            next if keys.include?(n)
            to = m.remap[n] or next
            v = voice_of[to] or next
            extra[v] << n
          end
          gm_map.to_h { |v, ns| [v, (ns + extra[v]).freeze] }.freeze
        end

        # One kit's drum map: the keys it has and its layout.  #key gives a
        # role's key (the layout's, its own GM key, or a fallback's), #remap
        # the keys to play in place of the keys generators write.
        class Map
          attr_reader :keys, :layout

          def initialize(keys, layout)
            @keys = keys
            @layout = layout
            l = layout && LAYOUTS.fetch(layout)
            @lmap = l ? l[:map].select { |_, k| keys.include?(k) } : {}
            @claimed = @lmap.values.uniq
            @remap = nil
            @missing = nil
          end

          # The key the kit plays for +role+, or nil when it has neither the
          # role nor a fallback.
          def key(role)
            [role.to_sym, *Roles.chain(role)].each do |r|
              k = own(r)
              return k if k
            end
            nil
          end

          # { written key => played key } for every role whose key the kit
          # plays as something else or lacks (keys it plays as written are
          # left out; nil: a key the kit has but uses for another role, for
          # a role it lacks, plays nothing).
          def remap
            @remap ||= NAMES.each_with_object({}) { |(n, role), h|
              k = key(role)
              if k.nil?
                h[n] = nil if @keys.include?(n) # (a key the layout plays as another role: silent, not the wrong drum)
              elsif k != n
                h[n] = k
              end
            }.freeze
          end

          # Roles that play nothing on this kit (no key, no fallback), one
          # name per key.
          def missing
            @missing ||= NAMES.values.select { |r| key(r).nil? }.freeze
          end

          def inspect
            "#<Drums::Roles::Map #{@layout || :gm} #{@keys.length} keys, #{remap.length} remapped, #{missing.length} missing>"
          end

          private

          # The kit's own key for +r+ (no fallback): the layout's, else its
          # GM key when the kit has that key and the layout doesn't use it
          # for something else.
          def own(r)
            n = NOTES[r] or return nil
            ALIASES[n].each { |a| return @lmap[a] if @lmap.key?(a) }
            return nil if @claimed.include?(n) || !@keys.include?(n)
            n
          end
        end
      end
    end
  end
end
