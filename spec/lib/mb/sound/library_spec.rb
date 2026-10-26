require 'fileutils'

# The library core (library-core-1; design/notes/library.md): entries, the
# index, Presettable, shelves and library files, save/save!/bump, collect,
# promote, the L heads, and Param positions.
RSpec.describe MB::Sound::Library do
  let(:lib) { MB::Sound::Library }
  let(:index) { lib.index }
  let(:user) { File.dirname(tmp_path('user/x')) }

  around do |ex|
    old = ENV.to_h.slice('MB_SOUND_USER_PRESETS', 'MB_SOUND_PRESETS')
    ENV.delete('MB_SOUND_PRESETS')
    ENV['MB_SOUND_USER_PRESETS'] = user
    lib.reload!
    index.clear_uses
    ex.run
  ensure
    ENV.delete('MB_SOUND_PRESETS')
    old.each { |k, v| ENV[k] = v }
    lib.reload!
  end

  def write(rel, text, dir: user)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    lib.reload!
    path
  end

  def render(graph, n = 20, size = 512)
    SpecBuffers.join(Array.new(n) { b = graph.sample(size); b&.dup })
  end

  describe MB::Sound::Library::Entry do
    it 'is a frozen value with checked fields and words for the heads' do
      e = lib::Entry.new(name: :dark_hall, kind: :effect, family: :reverb, tags: ['Dark', :big], about: 'x', settings: { decay: [1, 2] })
      expect(e).to be_frozen
      expect(e.tags).to eq(%i[dark big])
      expect(e.settings).to be_frozen
      expect(e.settings[:decay]).to be_frozen
      expect(e.words).to eq(%i[reverb dark big])
      expect(e.name_words).to eq(%i[dark hall])
      expect { lib::Entry.new(name: 'x', kind: :effect, family: :reverb) }.to raise_error(ArgumentError, /Symbols/)
      expect { lib::Entry.new(name: :x, kind: :sound, family: :reverb) }.to raise_error(ArgumentError, /Unknown entry kind/)
      expect { lib::Entry.new(name: :x, kind: :effect, family: :reverb).call }.to raise_error(ArgumentError, /holds data only/)
    end
  end

  describe MB::Sound::Presettable do
    let(:fresh) { lib::Index.new }

    before { allow(lib).to receive(:index).and_return(fresh) }

    def klass(&block)
      Class.new do
        extend MB::Sound::Presettable
        class_eval(&block)
      end
    end

    it 'declares presets with the class DSL line and looks them up with suggestions' do
      k = klass {
        preset_family :wobble, kind: :effect, label: 'wobble mode', keys: %i[rate depth], apply: ->(name, x, **o) { [name, x, o] }
        param :rate, 1.0, range: 0.1..10.0, curve: :exp, unit: 'Hz'
        preset :slow, rate: 0.5, depth: 0.2, tags: %i[gentle], about: 'Slow', aliases: %i[lazy]
        preset :fast, rate: 6.0, depth: 0.1, tags: %i[nervous]
      }
      expect(k.preset_names).to eq(%i[slow fast])
      expect(k.preset_settings(:slow)).to eq(rate: 0.5, depth: 0.2)
      expect(k.preset_settings(:lazy)).to eq(rate: 0.5, depth: 0.2)
      expect(k.preset?(:fast)).to be(true)
      expect(k.preset?(:medium)).to be(false)
      expect(k.presets[:slow].params[:rate].default).to eq(0.5)
      expect(k.presets[:slow].location).to match(/library_spec\.rb:\d+/)
      expect(k.presets[:fast].(:sig, x: 1)).to eq([:fast, :sig, { x: 1 }])
      expect { k.preset_entry(:slwo) }.to raise_error(ArgumentError, /Unknown wobble mode :slwo \(:slow, :fast\)\nDid you mean\?  :slow/)
      expect { k.class_eval { preset :odd, speed: 1 } }.to raise_error(ArgumentError, /wobble :odd: unknown setting :speed/)
    end

    it 'raises for a repeated shipped name and for a name that is another entry\'s tag' do
      k = klass {
        preset_family :wobble, kind: :effect
        preset :slow, tags: %i[gentle]
      }
      expect { k.class_eval { preset :slow } }.to raise_error(lib::Collision, /wobble :slow is defined twice/)
      expect { k.class_eval { preset :gentle } }.to raise_error(lib::Collision, /named like a tag of wobble :slow/)
      expect { k.class_eval { preset :warm, tags: %i[slow] } }.to raise_error(lib::Collision, /has tag :slow, the name of wobble :slow/)
      expect { k.class_eval { preset :wobble } }.to raise_error(lib::Collision, /named like the wobble family/)
    end
  end

  describe 'the shipped entries' do
    it 'are free of collisions and problems, and every family preset can be used or read' do
      expect(index.problems).to eq([])
      shipped = index.entries(shadowed: true).select { |e| e.shelf.shipped? }
      expect(index.conflicts.keys & shipped.map { |e| [e.family, e.name] }).to eq([])
      expect(shipped.map(&:kind).uniq).to include(:instrument, :effect, :kit, :master, :set, :envelope, :sample_edit)
      families = lib.families
      shipped.each do |e|
        expect(families).to have_key(e.family), e.label
        expect(e.builder || e.settings).not_to be_nil, e.label
        expect(e.to_ruby).to be_a(String)
        expect(e.head_path).to start_with('L.')
        # Every tag is a word, and no name is another entry's tag under the same head
        others = shipped.select { |o| o.kind == e.kind && !o.equal?(e) }
        expect(others.flat_map(&:tags)).not_to include(e.name), e.label
      end
    end

    it 'keep the class presets as they were (bit for bit)' do
      g = MB::Sound::GraphNode
      expect(g::Reverb.preset_settings(:hall)[:wet]).to eq(-20.db)
      expect(g::Reverb.presets[:plate].about).to eq('Dense and bright, a short plate (room-size layout)')
      expect(g::Chorus.mode(:juno)).to eq(rates: [0.513], min: 0.00166, max: 0.00535)
      expect(g::ModalResonator.from_preset(:tam_tam).glide).to eq(0.8)
      expect(MB::Sound::Envelope::Curves.values(:snappy)).to eq([24, 90, 60])
      expect(MB::Sound::Envelope::Curves.shape(:pad)).to eq(:s)
      expect(MB::Sound::Envelope.preset_settings(:amp_env)[:sensitivity]).to eq(-18.db..0.db)
      expect(MB::Sound::Sample::Lofi.preset_settings(:sp1200)).to eq(rate: 26_040, bits: 12, input_filter: false, filter: nil, read: :drop)
      expect(g::DynamicsMethods::Squeeze.preset_settings(:eleven)[:depth]).to eq(1.0)
      expect(MB::Sound::Mastering.from_preset(:club).title).to eq('Club: loud, low crest, mono lows')
      expect(MB::Sound::SQ80.patch(:classic).settings).to eq(transpose: -12, level: 1.99)
    end
  end

  describe 'library files on shelves' do
    let(:file) do
      <<~RUBY
        library 1
        wide = 0.6
        reverb :big_plate, room_size: wide, decay: 3.5, damping: 0.4, seed: 2,
          tags: %i[glassy], about: 'A big bright plate'
        chain :dubby, tags: %i[echo] do |sig|
          space = knob :space, 0.3, description: 'Echo level'
          sig + sig.delay(3.n16, feedback: space * 0.7, wet: space)
        end
        instrument :glass_keys, tags: %i[keys], about: 'Two detuned triangles' do |midi|
          cut = knob :cut, (300.hz..8000.hz).at(2400.hz)
          midi.synth { |v| (v.hz.triangle + v.hz.transpose(0.07).triangle).lp4(cut) * v.amp_env * 0.3 }
        end
        clip :walk_a, seq(A2, C3, E3, G3).n8.loop, tags: %i[walking]
      RUBY
    end

    it 'adds class presets, instruments, chains, and clips, found by name and used' do
      write('fx/mine.rb', file)
      expect(MB::Sound::GraphNode::Reverb.preset_names).to include(:big_plate)
      a = render(220.hz.saw.reverb(:big_plate))
      b = render(220.hz.saw.reverb(room_size: 0.6, decay: 3.5, damping: 0.4, seed: 2))
      expect(a).to eq(b)

      e = index.lookup(:preset, :glass_keys)
      expect(e.kind).to eq(:instrument)
      expect(e.shelf.name).to eq(:user)
      expect(e.params[:cut].default.frequency).to eq(2400)
      expect(e.location).to end_with('fx/mine.rb:9')
      expect(index.lookup(:reverb, :big_plate).source).to eq("wide = 0.6\n" + file.lines[2..3].join.chomp)

      rack = MB::Sound.preset(:glass_keys)
      expect(rack).to be_a(MB::Sound::Rack)
      expect(rack.kind).to eq(:instrument)
      synth = MB::Sound.preset(:glass_keys, midi: MB::Sound::Notes.new(MB::Sound.seq(MB::Sound::C3).n4))
      expect(synth).to be_a(MB::Sound::Synth)
      expect(render(synth, 10).abs.max).to be > 0.01
      expect(MB::Sound.preset(:dubby)).to be_a(MB::Sound::Rack)
      expect(index.lookup(:clip, :walk_a).call.events.length).to eq(4)
      expect(index.uses.map(&:label)).to include('reverb :big_plate', 'preset :glass_keys', 'preset :dubby')
    ensure
      MB::Sound::Session.existing&.close
    end

    it 'refuses files outside the format, listing them as problems' do
      write('bad.rb', "reverb :x, decay: 2\nif true then 1 end\n")
      write('typo.rb', "reverb :y, decya: 2\n")
      write('verb.rb', "shout :z\n")
      problems = index.problems.join("\n")
      expect(problems).to match(/bad\.rb.*if/)
      expect(problems).to match(/typo\.rb:1: reverb :y: unknown setting :decya \(did you mean decay\?\)/)
      expect(problems).to match(/verb\.rb:1: a library file holds entries/)
      expect(MB::Sound::GraphNode::Reverb.preset?(:y)).to be(false)
      expect { lib::FileLoader.load(File.join(user, 'bad.rb'), shelf: lib.shelf(:user)) }.to raise_error(MB::Sound::GraphIO::LoadError, /bad\.rb:2/)
    end

    it 'lets a user shelf shadow a built-in with a warning once, and find shows it' do
      write('fx/hall.rb', "reverb :hall, room_size: 0.9, decay: 5, tags: %i[huge]\n")
      expect { expect(MB::Sound::GraphNode::Reverb.preset_settings(:hall)).to eq(room_size: 0.9, decay: 5) }
        .to output(/Library: reverb :hall from .*fx\/hall\.rb:1 shadows the builtin shelf's/).to_stderr
      expect { MB::Sound::GraphNode::Reverb.preset_settings(:hall) }.not_to output.to_stderr
      expect(index.conflicts[[:reverb, :hall]].map { |e| e.shelf.name }).to eq([:builtin])
      expect(MB::Sound.find('hall huge').to_s).to match(/L\.fx\.hall +effect +user +name, tag huge +\(shadows builtin\)/)
    end
  end

  describe 'find' do
    it 'ranks entries matching every word, names over tags over descriptions, and explains why' do
      r = MB::Sound.find('dnb reese')
      expect(r.first.name).to eq(:dnb_reese)
      expect(r.hits.first.why).to eq(['name dnb', 'name reese'])
      expect(r.entries).to all(satisfy { |e| e.name.to_s.include?('reese') })
      expect(MB::Sound.find(:hall).first.name).to eq(:hall)
      bright = MB::Sound.find(:bright, kind: :effect)
      expect(bright.entries.map(&:kind).uniq).to eq([:effect])
      expect(bright.entries.map(&:name)).to include(:plate, :glass)
      expect(MB::Sound.find('zzzz').to_s).to eq('Nothing in the library matches zzzz')
    end
  end

  describe 'save, save!, and bump' do
    let(:graph) { MB::Sound::GraphIO.load("inputs :input\nparam :mix, 0.25\ninput * mix", inputs: { input: 1.constant }) }

    it 'never replaces a preset with save, replaces with save!, and bumps versions' do
      path = nil
      expect { path = MB::Sound.save(:quarter, graph, tags: %i[test quiet], about: 'A quarter') }.to output(/Saved quarter to .*quarter\.mbg\.rb \(committed\)/).to_stdout
      expect(path).to eq(File.join(user, 'quarter.mbg.rb'))
      doc = MB::Sound::GraphIO.parse(path)
      expect(doc.meta[:tags]).to eq(%i[test quiet])
      expect(doc.description).to eq('A quarter')
      expect(index.lookup(:preset, :quarter, note: false)).to be_nil # (documents aren't file entries)
      expect(MB::Sound.find('quiet test').first.name).to eq(:quarter)

      expect { expect(MB::Sound.save(:quarter, graph)).to be_nil }.to output(/Not saved: quarter exists .*bump: true saves :quarter_v2/).to_stderr
      expect { MB::Sound.save(:quarter, graph, bump: true) }.to output(/Saved quarter_v2 to/).to_stdout
      expect { MB::Sound.save(:quarter, graph, bump: true) }.to output(/Saved quarter_v3 to/).to_stdout
      expect { MB::Sound.save(:quarter_v3, graph, bump: true) }.to output(/Saved quarter_v4 to/).to_stdout
      other = MB::Sound::GraphIO.load("inputs :input\nparam :mix, 0.5\ninput * mix", inputs: { input: 1.constant })
      expect { MB::Sound.save!(:quarter, other) }.to output(/Saved quarter to .*\(replaced\) \(committed\)/).to_stdout
      expect(MB::Sound::GraphIO.parse(path).meta[:tags]).to eq(%i[test quiet]) # (kept by save!)

      log = `git -C #{user} log --format=%s`.lines.map(&:chomp)
      expect(log.first).to eq('mb-sound: save :quarter (replaced)')
      expect(log.length).to eq(5)
    end
  end

  describe 'collect and promote' do
    let(:project) { File.dirname(tmp_path('song/x')) }

    before do
      FileUtils.mkdir_p(project)
      File.write(File.join(project, 'Gemfile'), "gem 'mb-sound'\n")
      write('fx/mine.rb', "reverb :big_plate, room_size: 0.6, decay: 3.5, tags: %i[glassy]\n")
    end

    it 'copies the presets a song used into its presets/, pinned without warnings, and promotes them back out' do
      Dir.chdir(project) do
        lib.reload!
        expect(lib.shelves.map(&:name)).to eq(%i[session project user builtin])
        220.hz.saw.reverb(:big_plate)
        220.hz.saw.reverb(:hall)
        done = nil
        expect { done = MB::Sound.collect }.to output(/Collected reverb :big_plate from the user shelf to presets\/fx\/mine\.rb/).to_stdout
        expect(done.map { |e, _| e.name }).to eq([:big_plate]) # (built-ins stay with the gem)
        expect(File.read(File.join(project, 'presets/fx/mine.rb'))).to eq("library 1\n\nreverb :big_plate, room_size: 0.6, decay: 3.5, tags: %i[glassy]\n")
        expect { expect(index.lookup(:reverb, :big_plate).shelf.name).to eq(:project) }.not_to output.to_stderr
        expect { MB::Sound.collect }.to output(/Nothing to collect|already in/).to_stdout

        expect { MB::Sound.collect(builtin: true, only: [:hall]) }.to output(/Collected reverb :hall from the builtin shelf to presets\/reverb\.rb/).to_stdout
        lib.reload!
        expect { expect(MB::Sound::GraphNode::Reverb.preset_settings(:hall)).to eq(MB::Sound::GraphNode::Reverb.presets[:hall].settings) }.not_to output.to_stderr
        expect(index.lookup(:reverb, :hall).shelf.name).to eq(:project)
        expect(render(220.hz.saw.reverb(:hall))).to eq(MB::Sound.with_seed(1) { render(220.hz.saw.reverb(**index.conflicts[[:reverb, :hall]].first.settings)) })

        # A song preset onto the user shelf: never over a different one
        write('presets/fx/song.rb', "chorus :song_juno, rates: [0.2], min: 0.001, max: 0.004, tags: %i[gentle]\n", dir: project)
        expect { MB::Sound.promote(:song_juno, family: :chorus) }.to output(/Promoted chorus :song_juno from the project shelf to .*user\/fx\/song\.rb \(committed\)/).to_stdout
        expect(File.read(File.join(user, 'fx/song.rb'))).to include('chorus :song_juno, rates: [0.2]')
        write('presets/fx/song.rb', "chorus :song_juno, rates: [0.3], min: 0.001, max: 0.004\n", dir: project)
        expect { expect(MB::Sound.promote(:song_juno, family: :chorus)).to be_nil }.to output(/Not copied: chorus :song_juno differs/).to_stderr
        expect { MB::Sound.promote!(:song_juno, family: :chorus) }.to output(/\(replaced\)/).to_stdout
        expect(File.read(File.join(user, 'fx/song.rb'))).to eq("library 1\n\nchorus :song_juno, rates: [0.3], min: 0.001, max: 0.004\n")
      end
    end

    it 'copies graph documents whole' do
      Dir.chdir(project) do
        lib.reload!
        g = MB::Sound::GraphIO.load("inputs :input\nparam :mix, 0.25\ninput * mix", inputs: { input: 1.constant })
        MB::Sound::GraphIO.save(File.join(user, 'half.mbg.rb'), g)
        lib.reload!
        MB::Sound.preset(:half, input: 2.constant)
        expect { MB::Sound.collect }.to output(/Collected preset :half from the user shelf to presets\/half\.mbg\.rb/).to_stdout
        expect(File.read(File.join(project, 'presets/half.mbg.rb'))).to eq(File.read(File.join(user, 'half.mbg.rb')))
        expect(MB::Sound::GraphIO.find_preset(:half)).to eq(File.join(project, 'presets/half.mbg.rb'))
      end
    end

    it 'needs a project or a directory' do
      expect { MB::Sound.collect }.to raise_error(ArgumentError, /collect copies into a song's presets/)
    end
  end

  describe 'the L heads' do
    let(:l) { MB::Sound::L }

    it 'narrow by family, tag, and name words, giving entries by name' do
      expect(l.fx.reverb.names).to include(:hall, :plate, :default)
      expect(l.fx.reverb.hall).to eq(MB::Sound::GraphNode::Reverb.presets[:hall])
      expect(l.fx.hall.family).to eq(:reverb)
      expect(l.inst.reese.names).to eq(%i[dnb_reese jungle_reese])
      expect(l.inst.dnb.reese.name).to eq(:dnb_reese)
      expect(l.kit.tr909.family).to eq(:machine)
      expect(l.fx.bright.names).to include(:plate, :glass)
      expect(l.fx[:hall].name).to eq(:hall)
      expect { l.fx.revreb }.to raise_error(NoMethodError, /revreb/)
      expect { l.fx[:zzz] }.to raise_error(KeyError, /nothing under L\.fx is :zzz/)
      expect(l.fx.reverb.to_s).to start_with("L.fx.reverb: #{l.fx.reverb.size} entries")
      expect(220.hz.saw.then(&l.fx.hall)).to be_a(MB::Sound::GraphNode::Reverb)
      expect(l.fx.reverb.plate.head_path).to eq('L.fx.reverb.plate') # (resonator :plate too)
      expect(l.fx.hall.head_path).to eq('L.fx.hall')
    end

    it 'complete the words of a chain without running it' do
      c = MB::Sound::Library::Heads
      expect(c.completions('L.fx.re')).to eq(%w[L.fx.resonator L.fx.reverb])
      expect(c.completions('L.')).to include('L.inst', 'L.fx', 'L.all')
      expect(c.completions('MB::Sound::L.kit.tr')).to eq(%w[MB::Sound::L.kit.tr808 MB::Sound::L.kit.tr909])
      expect(c.completions('L.inst.dnb.')).to include('L.inst.dnb.dnb_reese', 'L.inst.dnb.reese')
      expect(c.completions('L.fx.zzz.')).to be_nil
      expect(c.completions('foo.bar')).to be_nil
    end
  end

  describe 'Param positions' do
    it 'map values to 0..1 along the curve and back, typed' do
      p = MB::Sound::Param
      cut = p.declare(:cutoff, (150.hz..8000.hz).at(2400.hz))
      expect(cut.position(150.hz)).to eq(0)
      expect(cut.position(8000.hz)).to be_within(1e-12).of(1)
      expect(cut.value(0.5).frequency).to be_within(1e-9).of(Math.sqrt(150 * 8000))
      expect(cut.value(cut.position(1000.hz)).frequency).to be_within(1e-9).of(1000)
      gain = p.declare(:gain, -12.db)
      expect(gain.position(-24.db)).to be_within(1e-12).of(0.5) # (-60..12 dB: even in dB)
      expect(gain.value(0.5)).to eq(-24.db)
      mix = p.declare(:mix, 0.3)
      expect(mix.position(0.3)).to eq(0.3)
      expect(mix.value(1.5)).to eq(1.5) # (outside the range: #check limits)
      voices = p.declare(:voices, 4)
      expect(voices.value(0.5)).to eq(17)
      mode = p.declare(:mode, :b, range: %i[a b c])
      expect(mode.position(:c)).to eq(1)
      expect(mode.value(0.4)).to eq(:b)
      expect(p.declare(:on, true).value(0.7)).to be(true)
      expect { p.declare(:x, 2.0).position(1) }.to raise_error(ArgumentError, /positions need a range/)
    end
  end
end
