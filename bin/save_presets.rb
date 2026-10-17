#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Saves (or checks) the presets that come with mb-sound, in presets/.
#
# Each instrument preset is a bin/synths/ script's patch saved with --save
# (so its numeric options become the document's params), and each effect
# preset an effect method from one of those scripts saved with GraphIO.save.
# The persona panel's patches (2026-10-13; bin/synths/dnb.rb, jungle.rb,
# ambient.rb, funk.rb, named for their genres) were the first, then
# bin/synths/electric_pianos.rb, then the SQ-80 voice's patches
# (bin/synths/sq80_voice.rb, sq80-lib-1); each document's description says where it
# came from (the scripts' <script>_description).
# Saves are deterministic (the library's default random seed), so saving
# again after a library change shows what changed in `git diff presets/`.
#
# Usage: $0 [options] [name ...]
#
# Examples:
#     $0                     # saves every preset into presets/
#     $0 dnb_reese jungle_keys
#     $0 --check             # lists presets whose saved text is out of date
#     $0 --list

require 'bundler/setup'
require 'fileutils'
require 'mb-sound'

module MB::Sound
  # The library's preset sources: { name => [script, patch, extra args] }
  # for script patches (saved with --save from spec/test_data/c_major.mid).
  LIBRARY_PRESET_PATCHES = {
    dnb_reese: ['bin/synths/dnb.rb', :reese],
    dnb_sub: ['bin/synths/dnb.rb', :sub],
    dnb_neuro: ['bin/synths/dnb.rb', :neuro],
    dnb_pad: ['bin/synths/dnb.rb', :pad],
    dnb_pluck: ['bin/synths/dnb.rb', :pluck],
    dnb_boom: ['bin/synths/dnb.rb', :boom],
    dnb_drums: ['bin/synths/dnb.rb', :drums],
    jungle_breaks: ['bin/synths/jungle.rb', :breaks],
    jungle_sub: ['bin/synths/jungle.rb', :sub],
    jungle_reese: ['bin/synths/jungle.rb', :reese],
    jungle_keys: ['bin/synths/jungle.rb', :keys],
    jungle_pad: ['bin/synths/jungle.rb', :pad],
    jungle_flute: ['bin/synths/jungle.rb', :flute],
    jungle_perc: ['bin/synths/jungle.rb', :perc],
    ambient_bowl: ['bin/synths/ambient.rb', :bowl],
    ambient_rin: ['bin/synths/ambient.rb', :rin],
    ambient_gong: ['bin/synths/ambient.rb', :gong],
    ambient_koto: ['bin/synths/ambient.rb', :koto],
    ambient_harp: ['bin/synths/ambient.rb', :harp],
    ambient_drone: ['bin/synths/ambient.rb', :drone],
    ambient_rainstick: ['bin/synths/ambient.rb', :rainstick],
    funk_beat: ['bin/synths/funk.rb', :beat],
    funk_perc: ['bin/synths/funk.rb', :perc],
    funk_bass: ['bin/synths/funk.rb', :bass],
    funk_keys: ['bin/synths/funk.rb', :keys],
    funk_clav: ['bin/synths/funk.rb', :clav],
    funk_talkbox: ['bin/synths/funk.rb', :talkbox],
    funk_choir: ['bin/synths/funk.rb', :choir],
    # (--pickup and --amp given, so they save as params: the script's defaults are each patch's own, nil)
    tine_piano: ['bin/synths/electric_pianos.rb', :tine, '--pickup', '0.5', '--amp', '1'],
    tine_crunch: ['bin/synths/electric_pianos.rb', :crunch, '--pickup', '0.5', '--amp', '4'],
    reed_piano: ['bin/synths/electric_pianos.rb', :reed, '--pickup', '1.0'],
  }.merge(
    # The SQ-80 voice's patches (sq80-lib-1, 2026-10-17), with each patch's
    # cutoff, reso, chop, and flutter given so they save as params (zero
    # chop or flutter is off, baked in)
    SQ80.patch_names.to_h { |n|
      s = SQ80.patch(n).full_settings
      args = %i[cutoff reso chop flutter].reject { |k| s[k] == 0 }.flat_map { |k| ["--#{k}", s[k].to_f.to_s] }
      [:"sq80_#{n}", ['bin/synths/sq80_voice.rb', n, *args]]
    }
  ).freeze

  # Effect presets: { name => [script, params, builder] }; the builder gets
  # the input and a Hash of param Constants (named after the params).
  LIBRARY_PRESET_EFFECTS = {
    ambient_tape: ['bin/synths/ambient.rb', { wear: { value: 0.6, range: 0.0..1.0, description: 'Tape wear 0..1' } },
                 ->(input, p) { ambient_tape(input, wear: p[:wear]) }],
    ambient_room: ['bin/synths/ambient.rb', { space: { value: 0.5, range: 0.0..1.0, description: 'Room level 0..1' } },
                 ->(input, p) { ambient_room(input, space: p[:space]) }],
    dnb_master: ['bin/synths/dnb.rb', {
                   air: { value: 20.0, range: 20.0..400.0, description: 'Highpass in Hz' },
                   drive: { value: 11.0, range: 0.0..24.0, description: 'Gain in dB into the clipper and limiter' },
                 },
                 ->(input, p) { dnb_master(input, air: p[:air], drive: p[:drive]) }],
    funk_dub_loop: ['bin/synths/funk.rb', {
                      dub: { value: 1.0, range: 0.0..1.0, description: 'Footswitch: 1 records into the 4-bar loop' },
                      keep: { value: 0.82, range: 0.0..0.99, description: 'Loop feedback per pass' },
                    },
                    ->(input, p) { funk_dub_loop(input, dub: p[:dub], keep: p[:keep]) }],
  }.freeze

  # The MIDI file script patches are saved from.
  LIBRARY_PRESET_MIDI = 'spec/test_data/c_major.mid'

  # Every library preset name.
  def self.library_preset_names
    LIBRARY_PRESET_PATCHES.keys + LIBRARY_PRESET_EFFECTS.keys
  end

  # Saves library preset +name+ into +dir+ (presets/ by default), returning
  # its path.
  def self.save_library_preset(name, dir: GraphIO.library_presets_dir)
    root = File.expand_path('..', __dir__)
    if (patch = LIBRARY_PRESET_PATCHES[name])
      script, which, *extra = patch
      env = { 'MB_SOUND_PRESETS' => dir }
      out = IO.popen(env, [File.join(root, script), '-q', '-p', which.to_s, *extra, '--save', name.to_s, File.join(root, LIBRARY_PRESET_MIDI), err: [:child, :out]], chdir: root, &:read)
      raise "#{script} -p #{which} --save #{name} failed: #{out}" unless $?.success?
      library_preset_file(dir, name)
    elsif (effect = LIBRARY_PRESET_EFFECTS[name])
      script, params, builder = effect
      require File.join(root, script)
      MB::Sound.with_seed(0) do
        input = ArrayInput.new(data: [Numo::SFloat.zeros(1)])
        constants = params.to_h { |k, spec| [k, spec[:value].constant.named(k.to_s)] }
        graph = builder.call(input, constants)
        Dir.chdir(root) do
          description = MB::Sound.public_send(:"#{File.basename(script, '.rb')}_description", "Effect :#{name}")
          GraphIO.save(
            File.join(dir, "#{name}#{GraphIO::EXTENSION}"), graph,
            inputs: { input: input }, params: params, from: script, kind: :effect, meta: { description: description }
          )
        end
      end
    else
      raise ArgumentError, "No library preset #{name}#{GraphIO.suggest(name, library_preset_names)}"
    end
  end

  # The document file of preset +name+ in +dir+ (a plain document or a
  # bundle's), or nil.
  def self.library_preset_file(dir, name)
    plain = File.join(dir, "#{name}#{GraphIO::EXTENSION}")
    return plain if File.file?(plain)

    bundled = File.join(dir, "#{name}.mbg", "#{name}#{GraphIO::EXTENSION}")
    File.file?(bundled) ? bundled : nil
  end

  # The text of a preset document without the lines that change on every
  # save (the time and the library version), for comparisons.
  def self.preset_body(path)
    File.read(path).lines.reject { |l| l.match?(/^\s*(saved|mb_sound):/) }.join
  end

  if main_script?(__FILE__)
    script(
      check: [false, '-c', 'Save into a temporary directory and list presets whose text differs from presets/ (exit 1 if any)'],
      list: [false, '-l', 'List the library presets and where they come from'],
    ) { |names, p|
      names = names.empty? ? library_preset_names : names.map(&:to_sym)
      if p.list
        names.each do |n|
          src = LIBRARY_PRESET_PATCHES[n]&.then { |s, w, *| "#{s} -p #{w}" } || "#{LIBRARY_PRESET_EFFECTS.fetch(n)[0]} (effect)"
          puts "#{n.to_s.ljust(16)} #{src}"
        end
      elsif p.check
        require 'tmpdir'
        stale = Dir.mktmpdir do |dir|
          names.reject { |n|
            save_library_preset(n, dir: dir)
            old = library_preset_file(GraphIO.library_presets_dir, n)
            old && preset_body(old) == preset_body(library_preset_file(dir, n))
          }
        end
        stale.each { |n| puts "#{n}: out of date (bin/save_presets.rb #{n})" }
        exit 1 unless stale.empty?
        puts "#{names.length} preset#{names.length == 1 ? '' : 's'} up to date"
      else
        names.each { |n| puts "Saved #{n} to #{save_library_preset(n)}" }
      end
    }
  end
end
