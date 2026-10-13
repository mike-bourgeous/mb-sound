# Graph-io phase 2: graph documents (.mbg.rb), loaded by walking their Prism
# syntax tree (GraphIO::Loader, no eval), written by GraphIO.dump, and kept
# as presets.
require 'open3'
require_relative '../../../support/graph_sweep'

RSpec.describe(MB::Sound::GraphIO, :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }
  let(:midi_path) { File.expand_path('../../../test_data/c_major.mid', __dir__) }
  let(:audio_path) { File.expand_path('../../../test_data/arp_a7.flac', __dir__) }

  def render(graph, buffers: 20, size: 512)
    RecipeHelpers.render(graph, buffers: buffers, size: size)
  end

  # Expects +text+ to fail to load with a LoadError on +line+ whose
  # message matches +message+.
  def expect_load_error(text, line, message, **opts)
    expect { io.load(text, **opts) }.to raise_error(io::LoadError) { |e|
      expect(e.message).to match(message)
      expect(e.line).to eq(line) if line
      expect(e.message).to include(":#{line}:") if line
    }
  end

  # The text of a document without the line that changes every save.
  def stable(doc)
    doc.sub(/saved: "[^"]*"/, 'saved: ...')
  end

  describe '.load' do
    it 'loads the Ruby that to_ruby prints, without a header' do
      g = 220.hz.ramp.filter(:lowpass, cutoff: 800).delay(1.n16.dotted).softclip
      h = io.load(g.to_ruby)
      expect(h.to_ruby).to eq(g.to_ruby)
      expect(render(h)).to eq(render(220.hz.ramp.filter(:lowpass, cutoff: 800).delay(1.n16.dotted).softclip))
    end

    it 'keeps tempo-synced pitches and LFOs tempo-synced' do
      make = -> { 220.hz.saw.lp4(1.bar.hz.transpose(-12).lfo.at(260..700)) + 3.n16.lfo.at(0.1) }
      code = make.().to_ruby
      expect(code).to include('1.bar.hz.transpose(-12)', '3.n16.hz.lfo') # (not 0.5.hz: the frequency at 120 BPM)
      expect(render(io.load(code), buffers: 300)).to eq(render(make.(), buffers: 300))
    end

    it 'binds inputs by name, from the header or to_ruby\'s inputs comment' do
      notes = MB::Sound::Notes.new(midi_path)
      synth = MB::Sound.synth(notes, voices: 2) { |v| v.hz.saw * v.amp_env }
      code = synth.to_ruby(inputs: { midi: notes })
      expect(code).to start_with('# inputs: midi')

      a = render(synth, buffers: 40)
      b = render(io.load(code, inputs: { midi: MB::Sound::Notes.new(midi_path) }), buffers: 40)
      expect(RecipeHelpers.max_diff(a, b)).to eq(0)
    end

    it 'raises for missing inputs and warns about extra ones' do
      expect_load_error("inputs :input\ninput.softclip", nil, /missing input input \(give input: \.\.\.\)/)
      expect { io.load("220.hz.ramp", inputs: { input: 1.constant }) }.to output(/ignoring input input/).to_stderr
    end

    it 'reads a header with the format, metadata, inputs, and params' do
      doc = <<~RUBY
        # A comment
        graph 1, name: "fuzz", kind: :effect, saved: "2026-10-11T00:00:00Z", mb_sound: "0.12.0"
        inputs :input
        param :drive, 2.0, range: 1.0..10.0, description: "Gain into the clipper", cc: 7

        (input * drive).softclip
      RUBY
      d = io.parse(doc)
      expect(d.name).to eq('fuzz')
      expect(d.kind).to eq(:effect)
      expect(d.inputs).to eq([:input])
      expect(d.params).to eq(drive: { value: 2.0, range: 1.0..10.0, description: 'Gain into the clipper', cc: 7 })

      g = io.load(doc, inputs: { input: 0.25.constant }, params: { drive: 3 })
      expect(g.sample(64).to_a).to eq((0.25.constant * 3.constant).softclip.sample(64).to_a)
      expect(io.document_of(g)[:drive]).to eq(3)
    end

    it 'refuses documents of a newer format' do
      expect_load_error("graph #{io::FORMAT + 1}\n220.hz.ramp", 1, /format #{io::FORMAT + 1}, newer than this mb-sound reads \(#{io::FORMAT}\)/)
    end

    it 'keeps the header first' do
      expect_load_error("220.hz.ramp\ninputs :input\ninput", 2, /inputs belongs in the header/)
      expect_load_error("inputs :input\ngraph 1\ninput", 2, /graph must come first/)
    end

    it 'needs a graph at the end' do
      expect_load_error("graph 1\n", nil, /no graph/)
      expect_load_error("x = 220.hz.ramp\n3", 2, /last line must be a graph/)
    end

    it 'gives line numbers and did_you_mean hints for unknown names and methods' do
      expect_load_error("x = 220.hz.ramp\nx.softclp", 2, /softclp isn't a graph method of a Tone \(did you mean softclip/)
      expect_load_error("osc = 220.hz.ramp\nosk.softclip", 2, /undefined name osk \(did you mean osc/)
      expect_load_error("220.hz.ramp.filter(:lowpass, cutoff: 800).dleay(0.1)", 1, /did you mean delay/)
      expect_load_error("Filter::Biquadd.new", 1, /unknown constant Filter::Biquadd \(did you mean Filter::Biquad/)
      expect_load_error("x = 220.hz.ramp.at(\n0.5).softclip\nx.fold", 3, /fold isn't a graph method/)
    end

    it 'loads notes, unit values, build blocks, and per_voice' do
      code = <<~RUBY
        # inputs: midi
        midi.synth(voices: 3) { |v|
          base = v.hz.glide(100.ms).transpose(per_voice(-0.1..0.1))
          (base.saw.at(-6.db) + C3.sine * 0.1) * v.amp_env(0.001, 0.2, 0.5, 0.1)
        }.delay(1.n8.dotted).feedback { |fb, input| input + fb.delay(5.ms) * 0.5 }
      RUBY
      g = io.load(code, inputs: { midi: MB::Sound::Notes.new(midi_path) })
      expect(g.to_ruby).to include('base = v.hz.glide(100.ms).transpose(per_voice(-0.1..0.1))')
      expect(render(g, buffers: 100).map { |c| c.abs.max }.max).to be > 0.01
    end
  end

  describe 'graph sweep round trips' do
    # Factories whose graphs can't be written yet, and why (phase 3)
    not_representable = {
      'wavetable sample mode reset' => "a Wavetable that isn't a library table",
      'ArrayInput' => "can't print a Numo::SFloat",
      'MixSource (master chain input)' => 'a class defined outside the library',
    }.freeze

    # Factories whose documents keep values but not moves: they save with a
    # comment and load, but render differently
    values_only = {
      'knob moves (Knob, Knob::Reader: a ramp, a jump, a followed node)' => '# :sweep was about to move (changes queued) when saved',
    }.freeze

    GraphSweep.factories.each do |name, factory|
      it "saves and loads #{name}" do
        MB::Sound.seed(1)
        graph = factory.call(GraphSweep::Context.new)
        if not_representable.key?(name)
          expect { io.dump(graph) }.to raise_error(io::DumpError, /#{Regexp.escape(not_representable[name])}/)
          next
        end
        if values_only.key?(name)
          doc = io.dump(graph, name: 'sweep')
          expect(doc).to include(values_only[name])
          expect(render(io.load(doc), buffers: 6, size: 128).map { |c| c.abs.max }.max).to be > 0
          next
        end

        doc = io.dump(graph, name: 'sweep')
        ref = render(graph, buffers: 6, size: 128)
        MB::Sound.seed(77)
        loaded = io.load(doc)
        expect(RecipeHelpers.max_diff(ref, render(loaded, buffers: 6, size: 128))).to eq(0), doc
        expect(stable(io.dump(loaded, name: 'sweep'))).to eq(stable(doc))
      end
    end
  end

  describe 'knobs' do
    let(:knob) { MB::Sound::GraphNode::Knob.new(:cut, 800, range: 50..4000, curve: :exp, unit: 'Hz', cc: 74) }
    let(:graph) { 110.hz.ramp.filter(:lowpass, cutoff: knob, quality: 2).lp4(knob) }

    it 'saves knobs as knob lines and loads them back as one knob' do
      doc = io.dump(graph, name: 'k')
      expect(doc).to include('knob :cut, 800.0, range: 50.0..4000.0, curve: :exp, unit: "Hz", cc: 74')
      expect(doc).to include('filter(:lowpass, cutoff: cut, quality: 2).lp4(cut)')
      loaded = io.load(doc)
      d = io.document_of(loaded)
      expect(d.knob?(:cut)).to eq(true)
      expect(d.knob_nodes[:cut].length).to eq(1)
      expect(d.knob_nodes[:cut][0]).to be_a(MB::Sound::GraphNode::Knob)
      expect(d.knob_nodes[:cut][0].spec).to eq(knob.spec)
      expect(RecipeHelpers.max_diff(render(graph, buffers: 6, size: 128), render(loaded, buffers: 6, size: 128))).to eq(0)
      expect(stable(io.dump(loaded))).to eq(stable(doc))
    end

    it 'overrides knob values on load and turns them with Document#set' do
      doc = io.dump(graph, name: 'k')
      loaded = io.load(doc, params: { cut: 2000 })
      k = io.document_of(loaded).knob_nodes[:cut][0]
      expect(k.value).to eq(2000)
      io.document_of(loaded)[:cut] = 300
      loaded.sample(800)
      loaded.sample(800)
      expect(k.value).to be_within(1e-3).of(300)
      expect(io.dump(loaded)).to include('knob :cut, 300')
    end

    it 'saves a moving knob at its current value with a comment' do
      knob.ramp_to(3000, frames: 48000, frame: 0)
      3.times { graph.sample(800) }
      doc = io.dump(graph, name: 'k')
      v = knob.value
      expect(doc).to match(/^# :cut was ramping to 3000 when saved; documents keep knob values, so it holds /)
      expect(io.document_of(io.load(doc)).knob_nodes[:cut][0].value).to eq(v)
    end

    it 'checks knob lines' do
      expect { io.load("knob :cut, 800, range: 0..4000, curve: :exp\n1.constant") }.to raise_error(io::LoadError, /range can't include 0/)
      expect { io.load("knob :cut, 800, colour: 1\n1.constant") }.to raise_error(io::LoadError, /unknown knob option colour/)
      expect { io.load("param :cut, 1\nknob :cut, 800\n1.constant") }.to raise_error(io::LoadError, /declared twice/)
    end

    it 'refuses two knobs with one name' do
      a = MB::Sound::GraphNode::Knob.new(:x, 0.5)
      b = MB::Sound::GraphNode::Knob.new(:x, 0.25)
      expect { io.dump(a + b) }.to raise_error(io::DumpError, /two different knobs are named :x/)
    end
  end

  describe 'params' do
    let(:doc) {
      <<~RUBY
        graph 1, name: "tremolo", options: { voices: 4 }
        inputs :input
        param :depth, 0.5, range: 0.0..1.0
        param :rate, 4.0, range: 0.5..20.0

        input * (1 - depth * rate.tone.sine.lfo.at(0..1))
      RUBY
    }

    it 'overrides defaults and makes a Constant per use' do
      a = io.load(doc, inputs: { input: 1.constant })
      b = io.load(doc, inputs: { input: 1.constant }, params: { depth: 0 })
      expect(render(b, buffers: 2).first.to_a.uniq).to eq([1.0])
      expect(render(a, buffers: 20).first.min).to be < 0.55
      expect(io.document_of(a).knob_nodes[:depth].length).to eq(1)
    end

    it 'changes every Constant of a param with Document#set' do
      g = io.load(doc, inputs: { input: 1.constant })
      io.document_of(g)[:depth] = 0
      g.sample(10)
      expect(g.sample(10).to_a.uniq).to eq([1.0])
    end

    it 'prints params back as names and keeps them on a re-save' do
      g = io.load(doc, inputs: { input: 1.constant }, params: { rate: 2.5 })
      again = io.dump(g)
      expect(again).to include("param :depth, 0.5, range: 0.0..1.0\nparam :rate, 2.5, range: 0.5..20.0")
      expect(again).to include('input * (1 - depth * rate.tone.sine.lfo.at(0..1))')
      expect(again).to include('options: { voices: 4 }')
    end

    it 'raises for unknown params, baked options, and non-numbers' do
      expect { io.load(doc, inputs: { input: 1.constant }, params: { dpeth: 1 }) }.to raise_error(io::LoadError, /no param dpeth \(did you mean depth/)
      expect { io.load(doc, inputs: { input: 1.constant }, params: { voices: 2 }) }.to raise_error(io::LoadError, /voices was baked into this patch/)
      expect { io.load(doc, inputs: { input: 1.constant }, params: { depth: 'x' }) }.to raise_error(io::LoadError, /needs a number/)
      expect { io.load(doc, inputs: { input: 1.constant }, params: { depth: 2 }) }.to output(/outside its range/).to_stderr
      expect_load_error("param :x, 1\nx = 3.constant\nx", 2, /x is an input or param and can't be assigned/)
      expect_load_error("param :x, :y\nx", 1, /needs a number/)
      expect_load_error("param :x, 1, rnage: 1..2\nx", 1, /unknown param option rnage/)
    end

    it 'turns script parameters into params with --save (a real script process)' do
      path = tmp_path('tape.mbg.rb')
      script = File.expand_path('../../../../bin/effects/tape_delay.rb', __dir__)
      out, status = Open3.capture2e({ 'OUTPUT_TYPE' => 'null' }, 'bundle', 'exec', 'ruby', script, audio_path, '--save', path, '-q', '--drive', '2')
      expect(status).to be_success, out
      expect(out).to include("Saved tape_delay.rb's graph to #{path}")

      text = File.read(path)
      expect(text).to include('from: "bin/effects/tape_delay.rb"')
      expect(text).to include('inputs :input')
      expect(text).to include('param :drive, 2.0, description: "Input gain into the tape"')
      expect(text).to match(/options: \{ pitch: false, delay: 0\.1, /)
      expect(text).to include('(input2 * drive).delay(0.1, feedback: 0.75')

      g = MB::Sound.preset(path, input: MB::Sound.file_input(audio_path).ringdown, drive: 0.5)
      expect(io.document_of(g)[:drive]).to eq(0.5)
      expect(render(g, buffers: 10).map { |c| c.abs.max }.max).to be > 0.01
    end
  end

  describe 'runtime blocks' do
    it 'loads blocks within the safe subset and prints them back' do
      code = "220.hz.ramp.proc { |buf| (buf * 3).clip(-0.5, 0.5) * 2 }"
      g = io.load(code)
      expect(g.to_ruby).to eq(code)
      expect(render(g)).to eq(render(220.hz.ramp.proc { |buf| (buf * 3).clip(-0.5, 0.5) * 2 }))
    end

    it 'allows math modules and its own locals in the safe subset' do
      g = io.load("220.hz.ramp.proc { |buf| y = buf * Math::PI\n Numo::NMath.sin(y) }")
      expect(render(g)).to eq(render(220.hz.ramp.proc { |buf| y = buf * Math::PI; Numo::NMath.sin(y) }))
    end

    it 'refuses blocks outside the subset unless named or trusted' do
      code = "220.hz.ramp.proc { |buf| buf.map { |x| x } }"
      expect_load_error(code, 1, /the proc block calls map, outside the safe subset.*named_proc.*trust: :code/)
      expect_load_error("220.hz.ramp.proc { |buf| buf.inplace }", 1, /calls inplace/)

      g = nil
      expect { g = io.load(code, trust: :code) }.to output(/trust: :code runs this block's saved Ruby source/).to_stderr
      expect(render(g)).to eq(render(220.hz.ramp))
    end

    it 'saves and loads named procs' do
      fold = MB::Sound.named_proc(:graph_io_spec_fold) { |buf| buf.map { |x| x.abs } }
      g = 220.hz.ramp.proc(&fold)
      code = g.to_ruby
      expect(code).to eq('220.hz.ramp.proc(&named_proc(:graph_io_spec_fold))')
      expect(render(io.load(code))).to eq(render(220.hz.ramp.proc(&fold)))
      expect_load_error('220.hz.ramp.proc(&named_proc(:graph_io_spec_nope))', 1, /no named proc :graph_io_spec_nope/)
    ensure
      io.procs.delete(:graph_io_spec_fold)
    end

    it 'loads lambda values in the subset' do
      g = io.load('220.hz.ramp.proc { |b| b * 0.5 } * 2')
      expect(render(g)).to eq(render(220.hz.ramp.proc { |b| b * 0.5 } * 2))
      expect_load_error('x = 3.constant; 220.hz.ramp.proc { |b| b * x }', 1, /reads x from the code around it/)
    end
  end

  describe 'safety' do
    {
      'if' => ["x = 1\nif x\n 220.hz.ramp\nend", 2, /if \(no flow control/],
      'ternary' => ["true ? 220.hz.ramp : 330.hz.ramp", 1, /if \(no flow control/],
      'unless' => ["unless false\n220.hz.ramp\nend", 1, /unless/],
      'case' => ["case 1\nwhen 1 then 220.hz.ramp\nend", 1, /case/],
      'while' => ["220.hz.ramp\nwhile true\nend", 2, /while/],
      'until' => ["until false\nend", 1, /until/],
      'for' => ["for x in 1..3\nend", 1, /for/],
      'def' => ["def x\nend\n220.hz.ramp", 1, /def/],
      'class' => ["class Foo\nend", 1, /class/],
      'module' => ["\nmodule Foo\nend", 2, /module/],
      'backticks' => ['`ls`', 1, /backticks/],
      '%x' => ['%x(ls)', 1, /backticks/],
      'system' => ["220.hz.ramp\nsystem('touch /tmp/x')", 2, /`system` is never allowed/],
      'eval' => ['eval("1")', 1, /`eval` is never allowed/],
      'instance_eval' => ['220.hz.ramp.instance_eval { 1 }', 1, /`instance_eval` is never allowed/],
      'send' => ['220.hz.ramp.send(:softclip)', 1, /`send` is never allowed/],
      'public_send' => ['220.hz.ramp.public_send(:softclip)', 1, /`public_send` is never allowed/],
      'const_get' => ['GraphNode::Mixer.const_get(:File)', 1, /`const_get` is never allowed/],
      'Kernel constant' => ["Kernel.exit", 1, /`exit` is never allowed/],
      'File' => ["File.read('/etc/passwd')", 1, /unknown constant File/],
      'Object' => ["Object.new", 1, /unknown constant Object/],
      'require' => ["require 'fileutils'", 1, /`require` is never allowed/],
      'global' => ['$x = 220.hz.ramp', 1, /global variables/],
      'global read' => ['$stdout', 1, /global variables/],
      'ivar' => ['@x = 220.hz.ramp', 1, /instance variables/],
      'cvar' => ['@@x', 1, /class variables/],
      'interpolation' => ['220.hz.ramp.named("#{1}")', 1, /string interpolation/],
      'safe navigation' => ['220.hz.ramp&.softclip', 1, /safe navigation/],
      'and' => ['220.hz.ramp && 330.hz.ramp', 1, /&&/],
      'or' => ['nil || 330.hz.ramp', 1, /\|\|/],
      'rescue' => ['220.hz.ramp rescue nil', 1, /rescue/],
      'begin' => ["begin\n220.hz.ramp\nensure\nend", 1, /begin/],
      'bare proc' => ['proc { 1 }', 1, /`proc` is never allowed/],
      'bare loop' => ['loop { }', 1, /`loop` is never allowed/],
      'bare lambda' => ['lambda { 1 }', 1, /`lambda` is never allowed/],
      'splat' => ['x = [1]; 220.hz.ramp.at(*x)', 1, /splats/],
      'double splat' => ['x = {}; 220.hz.ramp.at(1, **x)', 1, /double splats/],
      'multiple assignment' => ['a, b = 1, 2', 1, /multiple assignment/],
      'op assign' => ["x = 1\nx += 1", 2, /operator assignment/],
      'self' => ['self', 1, /self/],
      '__FILE__' => ['__FILE__', 1, /__FILE__/],
      'regexp' => ['/x/', 1, /regular expressions/],
      'BEGIN' => ['BEGIN { }', 1, /BEGIN/],
      'syntax error' => ["220.hz.ramp(\n", nil, /syntax error/],
      'method on a string' => ['"ls".freeze', 1, /freeze isn't a graph method of a String/],
      'unrecorded method' => ['220.hz.ramp.instance_variables', 1, /never allowed/],
      'sampling method' => ['220.hz.ramp.sample(100)', 1, /sample isn't a graph method/],
      'mb-math factorial' => ['1000000.factorial', 1, /factorial isn't a graph method/],
      'Marshal' => ["Marshal.load('x')", 1, /`load` is never allowed/],
      'Marshal constant' => ["Marshal", 1, /unknown constant Marshal/],
      'ObjectSpace' => ['ObjectSpace.each_object', 1, /unknown constant ObjectSpace/],
      'it parameter' => ['220.hz.ramp.proc { it * 2 }', 1, /implicit block parameters/],
      'numbered parameter' => ['220.hz.ramp.proc { _1 * 2 }', 1, /implicit block parameters/],
      'unsafe lambda' => ["x = ->(b) { system('ls') }", 1, /`system` is never allowed/],
      'iteration' => ['stereo(220.hz.ramp, 330.hz.ramp).map { |c| c }', 1, /map isn't a graph method/],
    }.each do |what, (text, line, message)|
      it "refuses #{what}" do
        expect_load_error(text, line, message)
      end
    end

    it 'never runs anything before rejecting a document' do
      flag = tmp_path('ran')
      expect_load_error("x = 220.hz.ramp\nsystem('touch #{flag}')", 2, /system/)
      expect(File.exist?(flag)).to eq(false)
    end

    describe 'limits' do
      it 'caps delay lengths' do
        expect_load_error('220.hz.ramp.delay(36000)', 1, /delay of 36000 seconds is over the limit of 60/)
        expect_load_error('220.hz.ramp.delay(0.1, max_delay: 10.hours)', nil, /hours isn't a graph method|undefined/)
        expect_load_error('220.hz.ramp.delay(0.1, max_delay: 3600.seconds)', 1, /max_delay: of 3600/)
        expect_load_error('220.hz.ramp.delay(1000.bars)', 1, /delay of \d+\.?\d* seconds is over the limit/)
        expect_load_error('220.hz.ramp.delay(48_000_000.samples)', 1, /over the limit/)
        expect_load_error('220.hz.ramp.multitap(1, 1000)', 1, /multitap of 1000/)
      end

      it 'caps buffers, voices, copies, oversampling, and repeats' do
        expect_load_error('220.hz.ramp.with_buffer(1_000_000_000)', 1, /with_buffer\(1000000000\) is over the limit/)
        expect_load_error('# inputs: midi
          midi.synth(voices: 10000) { |v| v.hz.saw }', 2, /synth\(10000\) is over the limit of 64/, inputs: { midi: MB::Sound::Notes.new(midi_path) })
        expect_load_error('220.hz.unison(1000) { |p, _i| p.saw }', 1, /unison\(1000\)/)
        expect_load_error('220.hz.ramp.oversample(1000)', 1, /oversample\(1000\)/)
        expect_load_error('seq(C4, E4).repeat(1_000_000)', 1, /repeat\(1000000\)/)
        expect_load_error('silence(100_000)', 1, /silence of 100000 seconds/)
      end

      it 'caps numbers, document size, depth, and calls' do
        expect_load_error('220.hz.ramp * 123456789012345678901234567890', 1, /too large/)
        expect_load_error('220.hz.ramp * 2 ** 100000', 1, /2 \*\* 100000 is too large/)
        expect_load_error("220.hz.ramp#{' ' * 1_000_001}", nil, /bytes \(the limit is 1000000\)/)
        deep = "#{'(' * 2000}220.hz.ramp#{')' * 2000}"
        expect_load_error(deep, 1, /nests deeper than 400 levels/)
        many = (['x = 220.hz.ramp'] + ['x = x.softclip'] * 100 + ['x']).join("\n")
        expect_load_error(many, nil, /more than 50 calls/, limits: { calls: 50 })
        expect(io.load(many)).to be_a(MB::Sound::GraphNode)
      end

      it 'reads files only relative to the document' do
        expect_load_error("file_input('/etc/passwd')", 1, /only documents loaded from a file/)
        path = tmp_path('reads.mbg.rb')
        File.write(path, "file_input('/etc/passwd')")
        expect_load_error(path, 1, /files must be named relative to the document/)
        File.write(path, "file_input('../x.flac')")
        expect_load_error(path, 1, /relative to the document/)

        FileUtils.cp(audio_path, tmp_path('arp.flac'))
        File.write(path, "file_input('arp.flac')")
        expect(render(io.load(path), buffers: 4).first.abs.max).to be > 0.01
      end

      # graph-io-3: before FileGuard, Wavetable['/abs/path'], tables named
      # by path in wavetable/phase_table/waveshape/KeyMap zones, and MIDI
      # file names given to Notes.new, synth, or tr808 opened any file
      [
        'Wavetable["%s"]',
        '440.hz.wavetable("%s")',
        '440.hz.wavetable(Wavetable["%s"])',
        '220.hz.ramp.phase_table("%s")',
        '220.hz.ramp.waveshape("%s")',
        '440.hz.wavetable(Wavetable::KeyMap.new({ (C1..C8) => "%s" }))',
        'Notes.new("%s").tone',
        'synth("%s") { |v| v.tone }',
        'tr808("%s")',
      ].each do |pattern|
        it "keeps file names in #{pattern % 'x'} relative to the document" do
          opened = []
          allow(MB::Sound::FFMPEGInput).to receive(:new).and_wrap_original { |m, f, **kw| opened << f; m.call(f, **kw) }
          allow(File).to receive(:open).and_wrap_original { |m, f, *a, **kw, &b| opened << f; m.call(f, *a, **kw, &b) }

          expect_load_error(pattern % '/etc/hostname', 1, /only documents loaded from a file/)
          expect_load_error(pattern % '/etc/hostname', 1, /relative to the document/, base_dir: tmp_path('docs'))
          expect_load_error(pattern % '../x.mid', 1, /relative to the document/, base_dir: tmp_path('docs'))

          dir = File.dirname(tmp_path('docs/x'))
          FileUtils.mkdir_p(dir)
          File.symlink('/etc/hostname', File.join(dir, 'link.flac'))
          expect_load_error(pattern % 'link.flac', 1, /link to outside the document's directory/, base_dir: dir)
          expect(opened.map(&:to_s).grep(%r{/etc/|\.\./})).to eq([])
        end
      end

      it 'reads tables and MIDI files named relative to the document' do
        dir = File.dirname(tmp_path('docs/x'))
        FileUtils.mkdir_p(dir)
        FileUtils.cp(audio_path, File.join(dir, 'arp.flac'))
        FileUtils.cp(File.expand_path('../../../test_data/c_major.mid', __dir__), File.join(dir, 'c.mid'))
        expect(io.load('440.hz.wavetable("arp.flac")', base_dir: dir).table.name).to eq('arp.flac')
        expect(render(io.load('Notes.new("c.mid").tone.ramp', base_dir: dir), buffers: 4).first.abs.max).to be > 0.1
      end

      it 'leaves file names from outside the document alone' do
        expect(io::FileGuard.resolve('/etc/hostname')).to eq('/etc/hostname')
        expect(io::FileGuard.resolve(audio_path.dup)).to eq(audio_path)
      end
    end

    it 'never uses eval, YAML, Marshal, send, or const_get outside TrustedCode' do
      files = Dir[File.expand_path('../../../../lib/mb/sound/graph_io{.rb,/*.rb}', __dir__)]
      expect(files.map { |f| File.basename(f) }).to include('graph_io.rb', 'loader.rb', 'registry.rb', 'document.rb', 'trusted_code.rb')
      files.each do |f|
        code = File.readlines(f).reject { |l| l.strip.start_with?('#') }.join
        # Symbols in Registry::FORBIDDEN are names, not calls
        code = code.gsub(/:(eval|instance_eval|class_eval|module_eval|send|__send__|const_get|binding)\b/, '')
        expect(code).not_to match(/YAML|Psych|Marshal|instance_eval|class_eval|module_eval|const_get|\b__send__\b/), f
        expect(code).not_to match(/(?<!public_)\bsend\(/), f
        if File.basename(f) == 'trusted_code.rb'
          expect(code.scan(/\beval[\s(]/).length).to eq(1)
        else
          expect(code).not_to match(/\beval[\s(]/), f
        end
      end
    end
  end

  describe 'presets' do
    around do |ex|
      old = ENV.to_h.slice('MB_SOUND_PRESETS', 'XDG_DATA_HOME')
      ENV['MB_SOUND_PRESETS'] = tmp_path('presets')
      ENV['XDG_DATA_HOME'] = tmp_path('xdg')
      ex.run
    ensure
      ENV.delete('MB_SOUND_PRESETS')
      ENV.delete('XDG_DATA_HOME')
      old.each { |k, v| ENV[k] = v }
    end

    it 'saves, lists, and loads presets with inputs and params as keywords' do
      graph = MB::Sound::GraphIO.load("inputs :input\nparam :mix, 0.25\ninput * mix", inputs: { input: 1.constant })
      path = nil
      expect { path = MB::Sound.save(:quarter, graph) }.to output(/Saved quarter to .*presets\/quarter\.mbg\.rb/).to_stdout
      expect(path).to eq(File.join(tmp_path('presets'), 'quarter.mbg.rb'))
      expect { MB::Sound.save(:quarter, graph) }.to output(/\(replaced\)/).to_stdout

      names = nil
      expect { names = MB::Sound.presets }.to output(/quarter  \(inputs: input; params: mix 0\.25\)/).to_stdout
      expect(names).to include(:quarter)
      expect(names - [:quarter]).to eq(io.presets[io.library_presets_dir]) # and mb-sound's own

      g = MB::Sound.preset(:quarter, input: 2.constant, mix: 0.5)
      expect(g.sample(4).to_a).to eq([1.0] * 4)
      expect { MB::Sound.preset(:quartr) }.to raise_error(io::LoadError, /no preset quartr \(did you mean quarter/)
    end

    it "doesn't save graphs it can't write" do
      graph = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 2, 3]])
      expect { expect(MB::Sound.save(:nope, graph)).to be_nil }.to output(/Not saved: can't save this graph yet/).to_stderr
    end

    it 'saves to a project\'s presets/, else the user data directory' do
      ENV.delete('MB_SOUND_PRESETS')
      project = tmp_path('song')
      FileUtils.mkdir_p(File.join(project, 'verse'))
      File.write(File.join(project, 'Gemfile'), "source 'https://rubygems.org'\ngem 'mb-sound', github: 'mike-bourgeous/mb-sound'\n")
      expect(io.project_dir(File.join(project, 'verse'))).to eq(project)
      Dir.chdir(File.join(project, 'verse')) { expect(io.presets_dir).to eq(File.join(project, 'presets')) }

      expect(io.project_dir(File.expand_path('../../..', __dir__))).to be_nil # the mb-sound checkout itself
      Dir.chdir(tmp_path('')) { expect(io.presets_dir).to eq(File.join(tmp_path('xdg'), 'mb-sound', 'presets')) } unless RUBY_PLATFORM.include?('darwin')
    end

    it 'refuses preset names that are paths in disguise' do
      expect(io.target_path('../x')).to eq(File.expand_path('../x.mbg.rb')) # a path: saved where it says
      expect { io.target_path('.hidden') }.to raise_error(ArgumentError, /preset names are words/)
    end
  end
end
