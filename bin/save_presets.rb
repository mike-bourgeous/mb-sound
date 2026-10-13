#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Saves (or checks) the presets that come with mb-sound, in presets/.
#
# Each instrument preset is a bin/synths/ script's patch saved with --save
# (so its numeric options become the document's params), and each effect
# preset an effect method from one of those scripts saved with GraphIO.save.
# The persona panel's patches (2026-10-13; bin/synths/kez_volta.rb,
# skylark_junction.rb, kaede_rowntree.rb, tiko_marvell.rb) are the first.
# Saves are deterministic (the library's default random seed), so saving
# again after a library change shows what changed in `git diff presets/`.
#
# Usage: $0 [options] [name ...]
#
# Examples:
#     $0                     # saves every preset into presets/
#     $0 kez_reese nev_rhodes
#     $0 --check             # lists presets whose saved text is out of date
#     $0 --list

require 'bundler/setup'
require 'fileutils'
require 'mb-sound'

module MB::Sound
  # The library's preset sources: { name => [script, patch, extra args] }
  # for script patches (saved with --save from spec/test_data/c_major.mid).
  LIBRARY_PRESET_PATCHES = {
    kez_reese: ['bin/synths/kez_volta.rb', :reese],
    kez_sub: ['bin/synths/kez_volta.rb', :sub],
    kez_neuro: ['bin/synths/kez_volta.rb', :neuro],
    kez_pad: ['bin/synths/kez_volta.rb', :pad],
    kez_pluck: ['bin/synths/kez_volta.rb', :pluck],
    kez_boom: ['bin/synths/kez_volta.rb', :boom],
    kez_drums: ['bin/synths/kez_volta.rb', :drums],
    nev_breaks: ['bin/synths/skylark_junction.rb', :breaks],
    nev_sub: ['bin/synths/skylark_junction.rb', :sub],
    nev_reese: ['bin/synths/skylark_junction.rb', :reese],
    nev_rhodes: ['bin/synths/skylark_junction.rb', :rhodes],
    nev_pad: ['bin/synths/skylark_junction.rb', :pad],
    nev_flute: ['bin/synths/skylark_junction.rb', :flute],
    nev_perc: ['bin/synths/skylark_junction.rb', :perc],
    kaede_bowl: ['bin/synths/kaede_rowntree.rb', :bowl],
    kaede_rin: ['bin/synths/kaede_rowntree.rb', :rin],
    kaede_gong: ['bin/synths/kaede_rowntree.rb', :gong],
    kaede_epiano: ['bin/synths/kaede_rowntree.rb', :epiano],
    kaede_harp: ['bin/synths/kaede_rowntree.rb', :harp],
    kaede_drone: ['bin/synths/kaede_rowntree.rb', :drone],
    kaede_rainstick: ['bin/synths/kaede_rowntree.rb', :rainstick],
    tiko_beat: ['bin/synths/tiko_marvell.rb', :beat],
    tiko_perc: ['bin/synths/tiko_marvell.rb', :perc],
    tiko_bass: ['bin/synths/tiko_marvell.rb', :bass],
    tiko_keys: ['bin/synths/tiko_marvell.rb', :keys],
    tiko_clav: ['bin/synths/tiko_marvell.rb', :clav],
    tiko_talkbox: ['bin/synths/tiko_marvell.rb', :talkbox],
    tiko_choir: ['bin/synths/tiko_marvell.rb', :choir],
  }.freeze

  # Effect presets: { name => [script, params, builder] }; the builder gets
  # the input and a Hash of param Constants (named after the params).
  LIBRARY_PRESET_EFFECTS = {
    kaede_tape: ['bin/synths/kaede_rowntree.rb', { wear: { value: 0.3, range: 0.0..1.0, description: 'Tape wear 0..1' } },
                 ->(input, p) { kaede_tape(input, wear: p[:wear]) }],
    kaede_room: ['bin/synths/kaede_rowntree.rb', { space: { value: 0.5, range: 0.0..1.0, description: 'Room level 0..1' } },
                 ->(input, p) { kaede_room(input, space: p[:space]) }],
    kez_master: ['bin/synths/kez_volta.rb', { air: { value: 20.0, range: 20.0..400.0, description: 'Highpass in Hz' } },
                 ->(input, p) { kez_master(input, air: p[:air]) }],
    tiko_dub_loop: ['bin/synths/tiko_marvell.rb', {
                      dub: { value: 1.0, range: 0.0..1.0, description: 'Footswitch: 1 records into the 4-bar loop' },
                      keep: { value: 0.82, range: 0.0..0.99, description: 'Loop feedback per pass' },
                    },
                    ->(input, p) { tiko_dub_loop(input, dub: p[:dub], keep: p[:keep]) }],
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
          GraphIO.save(File.join(dir, "#{name}#{GraphIO::EXTENSION}"), graph, inputs: { input: input }, params: params, from: script, kind: :effect)
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
