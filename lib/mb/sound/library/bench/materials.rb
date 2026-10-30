module MB
  module Sound
    module Library
      module Bench
        # What a preset plays on its Bench set (audition-1, 2026-10-30): a
        # +key+ (the group of the set and the argument of Entry#audition),
        # a +title+, the +bpm+ it plays at, +max_seconds+ (the render stops
        # there, faded out, if the preset still rings), and +source+: a
        # Proc giving a fresh dry stereo graph (effect materials) or a Clip
        # or Kit (instrument and kit phrases), +about+ for the item notes.
        Material = Data.define(:key, :title, :about, :bpm, :max_seconds, :source) do
          # A fresh dry graph or clip.
          def build = source.call

          # True for the audio materials effects process.
          def audio? = EFFECT_MATERIALS.include?(key)
        end

        # Audio materials for effects, in set order.
        EFFECT_MATERIALS = %i[arp break pad].freeze

        # Phrases for instruments by role, two each (generic, written here,
        # in A minor at 120 BPM unless a material says otherwise), plus the
        # entry's own genre template phrase when a template plays it.
        ROLE_MATERIALS = {
          bass: %i[bass_riff bass_long],
          lead: %i[lead_line lead_long],
          pad: %i[pad_chords pad_swell],
          keys: %i[keys_comp keys_arp],
          drums: %i[drums_beat drums_busy],
          texture: %i[texture],
          struck: %i[struck keys_comp],
        }.freeze

        # Words in role names, tags, and entry names that say what an
        # instrument is for (first match wins, in this order of roles).
        ROLE_WORDS = {
          drums: %i[drums drum beat perc breaks kit],
          texture: %i[texture weather rain wind riser noise rainstick build],
          bass: %i[bass sub reese acid roller neuro boom],
          pad: %i[pad pads strings drone choir swell slow],
          lead: %i[lead flute vox vowel talkbox pluck hook],
          keys: %i[keys piano clav organ stab brass chord chords harp koto bowl rin gong bell],
        }.freeze

        # Scenes looked at first for a template role's phrase (where the
        # part plays in full), then the rest in the template's order.
        SCENE_ORDER = %i[drop peak groove drop2 peak2 tide bloom].freeze

        # Kit rows for drum phrases (Audition's demo beat, and a busier one).
        BUSY_KIT = {
          kick: 'x..x..x...x..x..', snare: '....x..x.x..x..x', closed_hat: 'xxxxxxx.xxxxxxx.', open_hat: '.......x.......x',
        }.freeze

        # Note names (A3, Fs2) in the phrases here, as MB::Sound itself
        # resolves them.
        def self.const_missing(name)
          return super unless name != :Note && Note.name?(name)
          Note.new(name)
        end

        module_function

        # The dry audio materials (memoized per process: the pad renders
        # once): +:arp+ (spec/test_data/arp_a7.flac four times, 120 BPM),
        # +:break+ (breakbeat(:jungle) on both channels, at its own tempo),
        # +:pad+ (two minor chords on a plain saw pad written here).  With
        # +files+ ({ key => path } of float WAVs, see Bench.write_materials)
        # they are read from those files instead, so another checkout
        # processes the same samples (--vs).
        def audio(key, files: nil)
          @audio ||= {}
          return Sample[files[key.to_s] || files[key]].with(loop: nil) if files && (files[key.to_s] || files[key])
          @audio[key] ||= case key
                          when :arp
                            arp = Sample[arp_path]
                            Sample[arp.to_a.map { |c| Numo::SFloat.hstack([c] * 4) }]
                          when :break
                            brk = MB::Sound.breakbeat(:jungle)
                            Sample[[brk.data(0), brk.data(0)]]
                          when :pad
                            Sample[render_pad]
                          else
                            raise Error, "no audio material #{key.inspect} (#{EFFECT_MATERIALS.join(', ')})"
                          end
        end

        # spec/test_data/arp_a7.flac in this checkout of mb-sound.
        def arp_path
          File.expand_path('../../../../../spec/test_data/arp_a7.flac', __dir__)
        end

        # The pad material: Am to F, a bar each at 120 BPM, two detuned
        # saws through a gentle lowpass, slow attack and release.
        def pad_clip
          MB::Sound.seq([A3, C4, E4], [F3, A3, C4]).n1.legato(0.95)
        end

        # A pad voice for #pad_clip (also the plain instrument the dry pad
        # is played on).
        def pad_graph(clip = pad_clip)
          clip.synth(voices: 6) { |v|
            env = v.amp_env(0.35, 0.5, 0.85, 0.9, sensitivity: -6.db..0.db)
            ((v.hz.saw + v.hz.transpose(0.08).saw) * env * 0.12).filter(:lowpass, cutoff: 1800, quality: 0.7)
          }
        end

        def render_pad
          Bench.render_graph(MB::Sound.stereo(*Array.new(2) { pad_graph }), bpm: 120, max_seconds: 6)[0]
        end

        # The materials +entry+ plays on its Bench set (Material values).
        def materials_for(entry)
          case entry.kind
          when :effect
            EFFECT_MATERIALS.map { |k| effect_material(k) }
          when :kit
            [phrase(:drums_beat), phrase(:drums_busy), template_material(entry)].compact
          when :instrument
            role = role_of(entry)
            [*ROLE_MATERIALS.fetch(role).map { |k| phrase(k, entry) }, template_material(entry)].compact
          when :clip
            [Material.new(key: :clip, title: 'the clip on its instrument', about: 'the clip itself, on the instrument it plays on', bpm: 120, max_seconds: 12,
              source: -> { clip = entry.call; clip.respond_to?(:looping?) && clip.looping? ? once(clip, 2) : clip })]
          else
            []
          end
        end

        # The Material named +key+ for +entry+ (see #materials_for), or nil.
        def material(entry, key)
          key = key.to_sym
          materials_for(entry).find { |m| m.key == key } || (entry.kind == :instrument || entry.kind == :kit ? (phrase(key, entry) rescue nil) : nil)
        end

        # An effect's audio material.
        def effect_material(key, files: nil)
          case key
          when :arp
            Material.new(key: :arp, title: 'A7 arp (arp_a7.flac x4)', about: 'spec/test_data/arp_a7.flac four times: a stereo Am7/Amaj7 triangle arp',
              bpm: 120, max_seconds: 6, source: -> { audio(:arp, files: files).node })
          when :break
            Material.new(key: :break, title: 'Jungle break', about: 'breakbeat(:jungle) once, on both channels, at its own tempo',
              bpm: MB::Sound.breakbeat(:jungle).bpm.round(2), max_seconds: 7, source: -> { audio(:break, files: files).node })
          when :pad
            Material.new(key: :pad, title: 'Saw pad (Am, F)', about: 'two detuned saws through a lowpass, Am then F, a bar each at 120 BPM',
              bpm: 120, max_seconds: 8, source: -> { audio(:pad, files: files).node })
          else
            raise Error, "no effect material #{key.inspect} (#{EFFECT_MATERIALS.join(', ')})"
          end
        end

        # A generic phrase (ROLE_MATERIALS) as a Material.
        def phrase(key, entry = nil)
          title, about, bpm, seconds, clip = case key
            when :bass_riff
              ['Bass riff (16ths)', 'an A minor sixteenth riff, two bars twice', 120, 12,
               -> { (MB::Sound.seq(A1, A1, R, A2, R, A1, C2, R, A1, R, G1, R, E1, R, G1, A1).n16 |
                     MB::Sound.seq(F1, F1, R, F2, R, F1, A1, R, G1, R, G1, R, D2, R, C2, B1).n16).repeat(2) }]
            when :bass_long
              ['Bass, long notes', 'half and quarter notes from A1, two bars twice', 120, 12,
               -> { MB::Sound.seq(A1.n2, A1.n4, C2.n4, F1.n2, G1.n2).repeat(2) }]
            when :lead_line
              ['Lead line (8ths)', 'an A minor eighth-note line, two bars twice', 120, 12,
               -> { MB::Sound.seq(A4, C5, E5, D5, C5, E5, G5.n4, F5, E5, D5, C5, B4.n4, A4.n4).n8.repeat(2) }]
            when :lead_long
              ['Lead, long notes', 'E5 D5 C5 A4, held notes moving by step (glides show here)', 120, 10,
               -> { MB::Sound.seq(E5.n2, D5.n4, C5.n4, A4.n1).legato(1.0) }]
            when :pad_chords
              ['Pad chords', 'Am F C G, a bar each', 120, 13,
               -> { MB::Sound.seq([A3, C4, E4], [F3, A3, C4], [C4, E4, G4], [G3, B3, D4]).n1.legato(0.98) }]
            when :pad_swell
              ['Pad, one held chord', 'A2 E3 A3 C4 held for two bars at 60 BPM (attack and release show here)', 60, 13,
               -> { MB::Sound.seq([A2, E3, A3, C4]).n1 }]
            when :keys_comp
              ['Chords on the offbeats', 'Am and G stabs on the offbeats, two bars twice', 120, 12,
               -> { a = [A3, C4, E4]
                    g = [G3, B3, D4]
                    MB::Sound.seq(R, a, R, a, R, a, a, R, R, g, R, g, R, g, g, R).n8.repeat(2) }]
            when :keys_arp
              ['Arpeggio and chord (the demo phrase)', "Playable's demo phrase: C4 E4 G4 C5, then the C major chord", 120, 8,
               -> { Playable.demo_phrase }]
            when :drums_beat
              ['Drum beat', "Audition's demo beat (kick, snare, closed hat), four bars", 120, 10,
               -> { kit = MB::Sound.grid(16, **Audition::KIT_DEMO); repeat_kit(kit, 4) }]
            when :drums_busy
              ['Busy beat (open hats)', 'kick, snare, closed and open hats, four bars', 120, 10,
               -> { repeat_kit(MB::Sound.grid(16, **BUSY_KIT), 4) }]
            when :texture
              ['Held notes', 'A3 for a bar, four times (textures may ignore the notes)', 120, 10,
               -> { MB::Sound.seq(A3).n1.legato(0.98).repeat(4) }]
            when :struck
              ['Struck phrase', "Struck.phrase: the demo phrase moved toward the resonator's typical pitch", 120, 12,
               -> { Struck.phrase(entry.name) }]
            else
              raise Error, "no phrase #{key.inspect} (#{ROLE_MATERIALS.values.flatten.uniq.join(', ')}, template)"
            end
          Material.new(key: key, title: title, about: about, bpm: bpm, max_seconds: seconds, source: clip)
        end

        # A Kit whose rows each play +count+ bars (non-looping, so the
        # render ends when the voices ring out).
        def repeat_kit(kit, bars)
          Sequence::Kit.new(kit.rows.transform_values { |c| once(c, [(bars / c.length.to_r).ceil, 1].max) })
        end

        # A non-looping clip playing +clip+ +count+ times (Clip#repeated,
        # private there: #repeat warns for looping clips, which template
        # material is).
        def once(clip, count) = clip.send(:repeated, count)

        # The role an instrument plays (ROLE_MATERIALS keys): from the
        # genre template role that plays it, its tags, then its name words;
        # struck instruments are :struck; :keys otherwise.
        def role_of(entry)
          return :struck if entry.family == :struck
          words = [*template_roles(entry).map { |r| r[:role] }, *entry.tags, *entry.name_words]
          words.each do |w|
            ROLE_WORDS.each { |role, list| return role if list.include?(w) }
          end
          :keys
        end

        # Genre template roles whose patch is +entry+: [{ genre:, role:,
        # template: }], the entry's own genre (a tag or name word) first.
        def template_roles(entry)
          return [] unless %i[preset genre_patch machine].include?(entry.family)
          @template_roles ||= {}
          @template_roles[[entry.family, entry.name]] ||= begin
            names = Genre.names
            own = names.select { |g| entry.tags.include?(g) || entry.name_words.include?(g) }
            (own + (names - own)).flat_map { |g|
              t = MB::Sound.genre(g)
              t.roles.select { |_, r| r.patch == entry.name }.map { |name, _| { genre: g, role: name, template: t } }
            }
          end
        end

        # The entry's phrase from the first genre template that plays it
        # (SCENE_ORDER scenes first), at the template's tempo, repeated to
        # about 8 seconds (at most 12 s with the tail); nil if none.
        def template_material(entry)
          template_roles(entry).each do |r|
            t = r[:template]
            scenes = SCENE_ORDER.select { |s| t.scenes.key?(s) } + (t.scenes.keys - SCENE_ORDER)
            scenes.each do |s|
              name = t.scenes[s][r[:role]]
              next unless name.is_a?(Symbol)
              part = t.kits[name] || t.clips[name]
              next unless part
              bar = 240.0 / t.tempo
              len = part.is_a?(Sequence::Kit) ? part.rows.values.map(&:length).max : part.length
              seconds = len.to_f * bar
              count = (8.0 / seconds).round.clamp(1, 8)
              return Material.new(
                key: :template, title: 'Genre template phrase',
                about: "#{r[:genre]} :#{name} (role :#{r[:role]}, scene :#{s}) at #{t.tempo} BPM",
                bpm: t.tempo, max_seconds: [seconds * count + 4, 14].min.round(2),
                source: -> { part.is_a?(Sequence::Kit) ? repeat_kit(part, (len * count).ceil) : once(part, count) }
              )
            end
          end
          nil
        end
      end
    end
  end
end
