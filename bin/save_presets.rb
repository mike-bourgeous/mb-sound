#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Saves (or checks) the presets that come with mb-sound, in presets/.
#
# Each instrument preset is a bin/synths/ script's patch saved with --save
# (so its numeric options become the document's params), and each effect
# preset an effect method from one of those scripts saved with GraphIO.save.
# The persona panel's patches (2026-10-13; bin/synths/dnb.rb, jungle.rb,
# ambient.rb, funk.rb, named for their genres) were the first, then
# bin/synths/electric_pianos.rb, then the SQ-80 voice's patches
# (bin/synths/sq80_voice.rb, sq80-lib-1), then rack documents (racks R2:
# named racks from bin/songs/rack_demo.rb, saved with their knobs), then
# the wave voices (bin/synths/wave_voices.rb, protos-1: the research-sq80
# prototype patches, grit a param); each
# document's description says where it came from (the scripts'
# <script>_description).
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
require_relative 'synths/wave_voices' # (its patches' settings; guarded by main_script?)
require_relative 'synths/dnb' # (its patches' knobs, DNB_KNOBS; the same for the scripts below)
require_relative 'synths/jungle'
require_relative 'synths/funk'
require_relative 'synths/ambient'
require_relative 'synths/electric_pianos'
require_relative 'synths/init_voice'

module MB::Sound
  # Command-line options giving a patch's curated knobs (a Hash: name =>
  # value; library-instruments-1), so --save makes each one a param.
  def self.preset_knob_args(knobs)
    knobs.flat_map { |k, v| ["--#{k.to_s.tr('_', '-')}", v.to_s] }
  end

  # The library's preset sources: { name => [script, patch, extra args] }
  # for script patches (saved with --save from spec/test_data/c_major.mid).
  LIBRARY_PRESET_PATCHES = {
    dnb_reese: ['bin/synths/dnb.rb', :reese, *preset_knob_args(DNB_KNOBS[:reese])],
    dnb_sub: ['bin/synths/dnb.rb', :sub, *preset_knob_args(DNB_KNOBS[:sub])],
    dnb_neuro: ['bin/synths/dnb.rb', :neuro, *preset_knob_args(DNB_KNOBS[:neuro])],
    dnb_pad: ['bin/synths/dnb.rb', :pad, *preset_knob_args(DNB_KNOBS[:pad])],
    dnb_pluck: ['bin/synths/dnb.rb', :pluck, *preset_knob_args(DNB_KNOBS[:pluck])],
    dnb_boom: ['bin/synths/dnb.rb', :boom, *preset_knob_args(DNB_KNOBS[:boom])],
    dnb_drums: ['bin/synths/dnb.rb', :drums],
    jungle_breaks: ['bin/synths/jungle.rb', :breaks, *preset_knob_args(JUNGLE_KNOBS[:breaks])],
    jungle_sub: ['bin/synths/jungle.rb', :sub, *preset_knob_args(JUNGLE_KNOBS[:sub])],
    jungle_reese: ['bin/synths/jungle.rb', :reese, *preset_knob_args(JUNGLE_KNOBS[:reese])],
    jungle_keys: ['bin/synths/jungle.rb', :keys, *preset_knob_args(JUNGLE_KNOBS[:keys])],
    jungle_pad: ['bin/synths/jungle.rb', :pad, *preset_knob_args(JUNGLE_KNOBS[:pad])],
    jungle_flute: ['bin/synths/jungle.rb', :flute, *preset_knob_args(JUNGLE_KNOBS[:flute])],
    jungle_perc: ['bin/synths/jungle.rb', :perc],
    ambient_bowl: ['bin/synths/ambient.rb', :bowl, *preset_knob_args(AMBIENT_KNOBS[:bowl])],
    ambient_rin: ['bin/synths/ambient.rb', :rin, *preset_knob_args(AMBIENT_KNOBS[:rin])],
    ambient_gong: ['bin/synths/ambient.rb', :gong],
    ambient_koto: ['bin/synths/ambient.rb', :koto, *preset_knob_args(AMBIENT_KNOBS[:koto])],
    ambient_harp: ['bin/synths/ambient.rb', :harp],
    ambient_drone: ['bin/synths/ambient.rb', :drone, *preset_knob_args(AMBIENT_KNOBS[:drone])],
    ambient_rainstick: ['bin/synths/ambient.rb', :rainstick, *preset_knob_args(AMBIENT_KNOBS[:rainstick])],
    funk_beat: ['bin/synths/funk.rb', :beat],
    funk_perc: ['bin/synths/funk.rb', :perc],
    funk_bass: ['bin/synths/funk.rb', :bass, *preset_knob_args(FUNK_KNOBS[:bass])],
    funk_keys: ['bin/synths/funk.rb', :keys, *preset_knob_args(FUNK_KNOBS[:keys])],
    funk_clav: ['bin/synths/funk.rb', :clav, *preset_knob_args(FUNK_KNOBS[:clav])],
    funk_talkbox: ['bin/synths/funk.rb', :talkbox, *preset_knob_args(FUNK_KNOBS[:talkbox])],
    funk_choir: ['bin/synths/funk.rb', :choir, *preset_knob_args(FUNK_KNOBS[:choir])],
    # (--pickup and --amp given, so they save as params: the script's defaults are each patch's own, nil)
    tine_piano: ['bin/synths/electric_pianos.rb', :tine, '--pickup', '0.5', '--amp', '1', *preset_knob_args(ELECTRIC_PIANO_KNOBS[:tine])],
    tine_crunch: ['bin/synths/electric_pianos.rb', :crunch, '--pickup', '0.5', '--amp', '4', *preset_knob_args(ELECTRIC_PIANO_KNOBS[:tine])],
    reed_piano: ['bin/synths/electric_pianos.rb', :reed, '--pickup', '1.0', *preset_knob_args(ELECTRIC_PIANO_KNOBS[:reed])],
    # The init voice (sound-design-2): the blank patch, every knob a param
    init: ['bin/synths/init_voice.rb', :init, *preset_knob_args(INIT_KNOBS.transform_values(&:first))],
  }.merge(
    # The wave voices (protos-1, 2026-10-23: the research-sq80 prototype
    # patches of 2026-10-06), with each patch's cutoff, resonance, and grit
    # (0: clean) given so they save as params
    WAVE_VOICES.keys.to_h { |n|
      s = WAVE_VOICES.fetch(n)
      [n, ['bin/synths/wave_voices.rb', n, '--cutoff', s[:cutoff].to_s, '--reso', s[:reso].to_s, '--grit', '0.0']]
    },
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

  # Rack presets (rack documents, racks R2): { name => [script, method,
  # description] }; the script's method defines the named rack under the
  # preset's name and returns it.
  LIBRARY_PRESET_RACKS = {
    dub_echo: ['bin/songs/rack_demo.rb', :rack_demo_dub,
               'Rack :dub_echo from bin/songs/rack_demo.rb (racks-r2, 2026-10-17): dub echoes of the input, ' \
               'knob :space (echo level and feedback) and :tone (the echoes\' lowpass, swinging slowly around the knob)'],
  }.freeze

  # Set presets (`demo`, ux-r3 item 26): { name => [script, setup method,
  # form method, form options, description] }; the script's setup builds
  # the set (tracks, scenes, knobs, master) in a sandbox Session and its
  # form method the flow, then the Arrangement is saved as a set document.
  # (tunnel_vision since genre-fixes, 2026-10-18, when set documents
  # learned buses, sends, and routes.)
  LIBRARY_PRESET_SETS = {
    night_bus: ['bin/songs/night_bus_flow.rb', :last_stop, :last_stop_form, {},
                'Set :night_bus from bin/songs/night_bus_flow.rb ("Night Bus: Last Stop", tech house at 126 BPM in A minor): ' \
                'drums, sub, bass, hooks, plucks, pad, riser; scenes intro..outro; knobs :cut, :space, :echo, :air, :morph; ' \
                'its flow (play_form doc.form).  `demo` loads it.'],
    tunnel_vision: ['bin/songs/tunnel_vision.rb', :tunnel_vision, :tunnel_vision_form, { play: false },
                    'Set :tunnel_vision from bin/songs/tunnel_vision.rb ("Tunnel Vision", Kez Volta\'s drum & bass at 174 BPM in F minor, ' \
                    'the buses demo): drums, Reese, sub, neuro, boom, riser, pad, pluck; a :hall bus (ducked by the kick) and an :echo bus with sends, ' \
                    'the basses ducked by the drums\' kick voice; scenes intro..tail; knobs :cut, :grit, :space, :air, :lift; ' \
                    'its flow (play_form doc.form).  `demo :tunnel_vision` loads it.'],
  }.freeze

  # The MIDI file script patches are saved from.
  LIBRARY_PRESET_MIDI = 'spec/test_data/c_major.mid'

  # Every library preset name.
  def self.library_preset_names
    LIBRARY_PRESET_PATCHES.keys + LIBRARY_PRESET_EFFECTS.keys + LIBRARY_PRESET_RACKS.keys + LIBRARY_PRESET_SETS.keys
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
    elsif (rk = LIBRARY_PRESET_RACKS[name])
      script, method, description = rk
      require File.join(root, script)
      MB::Sound.with_seed(0) do
        rack = Session.with_context(session: Session.new(realtime: false, output: NullOutput.new(channels: 2, sleep: false))) {
          MB::Sound.public_send(method, name)
        }
        Dir.chdir(root) do
          GraphIO.save(File.join(dir, "#{name}#{GraphIO::EXTENSION}"), rack, from: script, meta: { description: description })
        end
      end
    elsif (st = LIBRARY_PRESET_SETS[name])
      script, setup, form, form_options, description = st
      require File.join(root, script)
      MB::Sound.with_seed(0) do
        # (its own transport: the set sets the tempo and meter)
        box = Session.new(realtime: false, output: NullOutput.new(channels: 2, sleep: false), transport: Sequence::Transport.new(bpm: 120))
        begin
          Dir.chdir(root) do
            Session.with_context(session: box) do
              MB::Sound.public_send(setup)
              MB::Sound.public_send(form, **form_options)
            end
            GraphIO.save(File.join(dir, "#{name}#{GraphIO::EXTENSION}"), box.arrangement, from: script, meta: { description: description })
          end
        ensure
          box.close
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
  # save (the time and the library version) and with its format version
  # left out (a format bump alone doesn't make every preset out of date),
  # for comparisons.
  def self.preset_body(path)
    File.read(path).lines.reject { |l| l.match?(/^\s*(saved|mb_sound):/) }.join.sub(/^graph \d+,/, 'graph N,')
  end

  if main_script?(__FILE__)
    script(
      check: [false, '-c', 'Save into a temporary directory and list presets whose text differs from presets/ (exit 1 if any)'],
      list: [false, '-l', 'List the library presets and where they come from'],
    ) { |names, p|
      names = names.empty? ? library_preset_names : names.map(&:to_sym)
      if p.list
        names.each do |n|
          src = LIBRARY_PRESET_PATCHES[n]&.then { |s, w, *| "#{s} -p #{w}" } ||
                LIBRARY_PRESET_RACKS[n]&.then { |s, m, *| "#{s} #{m} (rack)" } ||
                LIBRARY_PRESET_SETS[n]&.then { |s, m, *| "#{s} #{m} (set)" } ||
                "#{LIBRARY_PRESET_EFFECTS.fetch(n)[0]} (effect)"
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
