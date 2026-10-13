# Graph-io phase 1: recorded DSL calls (GraphNode::Recipe) and the Ruby they
# print (Recipe::RubyWriter, GraphNode#to_ruby).  The round-trip examples
# evaluate the printed code (our own output; the later loader won't eval)
# and compare renders sample for sample.
require_relative '../../../../support/graph_sweep'

RSpec.describe(MB::Sound::GraphNode::Recipe, :aggregate_failures) do
  let(:recipe) { MB::Sound::GraphNode::Recipe }
  let(:midi_path) { File.expand_path('../../../../test_data/c_major.mid', __dir__) }

  # Evaluates +code+ in the MB::Sound context (constants like A3 resolve as
  # in the console).
  def rebuild(code, inputs = {})
    RecipeHelpers.eval_recipe(code, inputs)
  end

  def render(graph, buffers: 40, size: 512)
    RecipeHelpers.render(graph, buffers: buffers, size: size)
  end

  # Builds a graph with the block, prints it, rebuilds it after another
  # root seed (+same_seed+ for code warning that seeds aren't printed), and
  # expects the same samples.  Returns the printed code.
  def round_trip(inputs: -> { {} }, buffers: 40, &build)
    MB::Sound.seed(5)
    given = inputs.call
    graph = build.call(given)
    code = MB::Sound::GraphNode::Recipe::RubyWriter.new(graph, inputs: given, seeds: true).to_s
    expect(code).not_to include('FIXME')
    ref = render(graph, buffers: buffers)

    MB::Sound.seed(code.include?('MB::Sound.seed') ? 5 : 99)
    copy = rebuild(code, inputs.call)
    got = render(copy, buffers: buffers)
    expect(got.map(&:length)).to eq(ref.map(&:length))
    expect(RecipeHelpers.max_diff(ref, got)).to eq(0), "#{code}\nrenders differently"
    expect(ref.map { |r| r.abs.max }.max).to be > 0
    code
  end

  describe 'recording' do
    it 'records only the outermost call' do
      f = 220.hz.ramp.filter(:lowpass, cutoff: 800, quality: 2)
      call = recipe.call_of(f)
      expect(call.name).to eq(:filter)
      expect(call.kwargs).to eq(cutoff: 800, quality: 2)
      # #filter's internal nodes have no recipes of their own
      inner = f.graph.reject { |n| recipe.record_of(n) }
      expect(inner).not_to be_empty
    end

    it 'appends calls returning their receiver to the configuration list' do
      t = 220.hz.ramp
      t2 = t.at(0.5).named('x')
      expect(t2).to equal(t)
      expect(recipe.call_of(t).name).to eq(:ramp)
      expect(recipe.config_of(t).map(&:name)).to eq([:at, :named])
    end

    it 'keeps one recipe per block scope for objects shared between synth lanes' do
      ccs = []
      MB::Sound.synth(midi_path, voices: 2, spares: 0) { |v| ccs << v.cc(1); v.hz.saw * v.amp_env * ccs.last }
      expect(ccs[0]).to equal(ccs[1])
      calls = ccs.each_with_index.map { |c, i| recipe.call_of(c, recipe.record_of(c).scoped&.keys&.[](i - 1) || recipe.call_of(c).scope) }
      expect(calls.map(&:name).uniq).to eq([:cc])
      expect(recipe.record_of(ccs[0]).scoped.length).to eq(1)
    end

    it "records build block invocations with their arguments, results, and the block's locals" do
      s = MB::Sound.synth(midi_path, voices: 2, spares: 1) { |v, _i| base = v.hz.saw; base * v.gate }
      invs = recipe.call_of(s).invocations
      expect(invs.length).to eq(3)
      expect(invs.map { |i| i.args[1] }).to eq([0, 1, 2])
      expect(invs.map { |i| i.locals[:base] }.map { |b| recipe.call_of(b, nil)&.name }).to all(eq(:saw))
      expect(invs[0].result).to be_a(MB::Sound::GraphNode::Multiplier)
    end

    context 'when reading build block locals' do
      around do |ex|
        old = recipe.locals_mode
        ex.run
      ensure
        recipe.locals_mode = old
      end

      # A TracePoint makes YJIT discard all of its compiled code, so the
      # default must never enable one (scene-build: render spikes after
      # every graph built while playing)
      it 'reads them from the block frame without a TracePoint by default' do
        expect(recipe.locals_mode).to eq(:frame)
        expect(TracePoint).not_to receive(:new)
        s = MB::Sound.synth(midi_path, voices: 2, spares: 0) { |v| base = v.hz.saw; later = base * v.gate; later }
        invs = recipe.call_of(s).invocations
        expect(invs.map { |i| i.locals.keys & [:base, :later] }).to all(eq([:base, :later]))
        expect(invs.map { |i| i.locals[:later] }).to eq(invs.map(&:result))
        expect(invs.map(&:frame)).to all(be_nil)
      end

      # The TracePoint also fired when blocks nested inside the build block
      # returned, so their locals leaked into the build block's: here the
      # feedback block's `input` named the oscillator, printing
      # `input = ...` and `input.feedback { |fb, input| ... }`
      it "finds the build block's own locals, as the TracePoint did, without nested blocks' locals" do
        build = -> {
          MB::Sound.seed(5)
          MB::Sound.synth(midi_path, voices: 2, spares: 1) { |v, i|
            osc = v.hz.ramp.filter(:lowpass, cutoff: 500 + 100 * i)
            env = v.amp_env(0.01, 0.1, 0.5, 0.2)
            wet = osc.feedback { |fb, input| inner = fb.delay(2.ms) * 0.3; input + inner }
            wet * env
          }
        }
        recipe.locals_mode = :trace
        traced = build.call
        recipe.locals_mode = :frame
        framed = build.call

        names = ->(s) { recipe.call_of(s).invocations.map { |i| i.locals.keys.sort } }
        expect(names.(framed)).to eq(names.(traced).map { |n| n - [:fb, :input, :inner] })
        expect(names.(framed).flatten).to include(:osc, :env, :wet)
        loop_names = ->(s) {
          recipe.call_of(s).invocations.map { |i| recipe.call_of(i.locals[:wet], i).invocations.map { |li| li.locals.keys.sort } }
        }
        expect(loop_names.(framed)).to eq(loop_names.(traced))
        expect(loop_names.(framed).flatten).to include(:inner)

        code = framed.to_ruby
        expect(code).to include('osc = v.hz.ramp', 'wet = osc.feedback { |fb, input|', 'inner = fb.delay(2.ms) * 0.3')
        expect(code).to eq(traced.to_ruby.gsub('input = v.hz', 'osc = v.hz').gsub('input.feedback', 'osc.feedback'))
      end

      it 'names nothing for blocks made from methods' do
        expect(recipe.block_iseq(method(:puts).to_proc)).to be_nil
        expect(recipe.block_iseq(:abs.to_proc)).to be_nil
        expect(recipe.block_iseq(proc { 1 })).to be_a(RubyVM::InstructionSequence)
      end

      it 'rejects unknown modes' do
        expect { recipe.locals_mode = :other }.to raise_error(ArgumentError, /:frame or :trace/)
      end
    end

    it 'keeps the arity and parameters of wrapped build blocks' do
      seen = nil
      220.hz.ramp.feedback { |fb| seen = fb; fb.delay(1.ms) * 0.5 }
      expect(seen).to be_a(MB::Sound::GraphNode)
      inv = nil
      220.hz.ramp.feedback { |fb, input| inv = [fb, input]; input + fb.delay(1.ms) * 0.5 }
      expect(inv.compact.length).to eq(2)
    end

    it 'leaves runtime blocks unwrapped' do
      blk = proc { |buf| buf * 0.5 }
      node = 220.hz.ramp.proc(&blk)
      call = recipe.call_of(node)
      expect(call.block_kind).to eq(:runtime)
      expect(call.block).to equal(blk)
      expect(call.invocations).to be_nil
    end

    it 'records .new from user code only' do
      m = MB::Sound::GraphNode::Mixer.new([220.hz.ramp, 330.hz.ramp])
      expect(recipe.call_of(m).name).to eq(:new)
      # x + y makes a Mixer inside the library
      sum = 220.hz.ramp + 330.hz.ramp
      expect(recipe.call_of(sum).name).to eq(:+)
    end

    it 'remembers the seeds a call drew' do
      n = MB::Sound.noise
      expect(recipe.call_of(n).seeds.length).to eq(1)
      expect(MB::Sound.noise(seed: 3).then { |x| recipe.call_of(x).seeds }).to be_nil
    end

    it 'notes the channels of recorded bundles as element access' do
      b = MB::Sound.stereo(220.hz.ramp, 330.hz.ramp).reverb(:room)
      l, r = b
      expect([l, r].map { |x| recipe.call_of(x).name }).to eq([:[], :[]])
      expect([l, r].map { |x| recipe.call_of(x).args }).to eq([[0], [1]])
    end

    it 'records nothing while turned off' do
      recipe.enabled = false
      x = 220.hz.ramp.softclip
      expect(recipe.record_of(x)).to be_nil
    ensure
      recipe.enabled = true
    end

    it 'records aliases under the name the code used, sharing one recorder' do
      expect(MB::Sound::Pitch.instance_method(:additive)).to eq(MB::Sound::Pitch.instance_method(:harmonics))
      x = 110.hz.additive([1, 0.5])
      expect(recipe.call_of(x).name).to eq(:additive)
    end

    describe 'surface guard' do
      let(:surface) { recipe::Surface }

      # The first method in the ancestry is a recorder
      def recorded?(klass, name)
        m = klass.instance_method(name)
        m.owner.name.nil? && m.source_location&.first&.end_with?('graph_node/recipe.rb')
      end

      it 'records every GraphNode DSL method on every node class, or lists it as exempt' do
        dsl = surface.graph_node_dsl
        exempt = recipe::EXEMPT['MB::Sound::GraphNode'].keys
        all = MB::Sound::GraphNode.included_modules
          .select { |m| m.name&.end_with?('Methods') && m.name.start_with?('MB::Sound::GraphNode::') }
          .flat_map { |m| m.public_instance_methods(false) }.uniq
        expect(all - dsl - exempt - surface::NEVER).to eq([])
        expect(exempt - all).to eq([]) # exempt names that no longer exist

        classes = ObjectSpace.each_object(Class).select { |c| c.name&.start_with?('MB::Sound') && c.include?(MB::Sound::GraphNode) }
        expect(classes.length).to be > 50
        missing = classes.flat_map { |c| (dsl & c.public_instance_methods).reject { |n| recorded?(c, n) }.map { |n| "#{c}##{n}" } }
        expect(missing).to eq([])
      end

      it 'records every public method of the DSL classes, or lists it as exempt' do
        surface.classes.each do |c|
          exempt = surface::EXEMPT[c.name]&.fetch(:names) || []
          candidates = c.public_instance_methods(false).reject { |m| m.end_with?('?', '=') || m.start_with?('plan_') || surface::NEVER.include?(m) }
          missing = (candidates - exempt).reject { |n| recorded?(c, n) }
          expect(missing).to eq([]), "#{c}: #{missing}"
          expect(exempt - c.public_instance_methods(false)).to eq([]), "#{c} exempts methods it doesn't have"
        end
      end

      it 'records the top-level graph methods' do
        surface::TOP.each do |mod, exempt|
          names = MB::Sound.const_get(mod).public_instance_methods(false)
          missing = (names - exempt.keys).reject { |n| recorded?(MB::Sound.singleton_class, n) }
          expect(missing).to eq([]), "#{mod}: #{missing}"
          expect(exempt.keys - names).to eq([])
        end
        expect(recorded?(MB::Sound.singleton_class, :file_input)).to eq(true)
      end
    end
  end

  describe 'printing' do
    it 'prints chains as written, with units' do
      g = 220.hz.ramp.filter(:lowpass, cutoff: 800, quality: 2).delay(250.ms).softclip * -6.db
      expect(g.to_ruby).to eq('220.hz.ramp.filter(:lowpass, cutoff: 800, quality: 2).delay(250.ms).softclip * -6.db')
      expect(MB::Sound::A3.saw.delay(1.n16.dotted).to_ruby).to eq('A3.saw.delay(1.n16.dotted)')
      expect(110.hz.ramp.delay(3.n16).delay(1.n8.triplet).delay(2.bars).to_ruby).to eq('110.hz.ramp.delay(3.n16).delay(1.n8.triplet).delay(2.bars)')
      expect(220.hz.transpose(1.oct).ramp.delay(96.samples).to_ruby).to eq('220.hz.transpose(1.oct).ramp.delay(96.samples)')
    end

    it 'prints notes of octave -1 as Note.new(n), marks included (Fs-1 would be Fs minus 1)' do
      clip = MB::Sound.seq(MB::Sound::Note.new(6), MB::Sound::Tie, !MB::Sound::Note.new(7), MB::Sound::C0).n16
      code = clip.to_ruby
      expect(code).to eq('seq(Note.new(6), Tie, !Note.new(7), C0).n16')
      expect(rebuild(code).events).to eq(clip.events)
    end

    it 'prints operators with the parentheses they need' do
      a = 220.hz.sine
      b = 330.hz.sine
      expect((a * (b + 1) - 0.5).to_ruby).to eq('220.hz.sine * (330.hz.sine + 1) - 0.5')
      expect((0.5 * 220.hz.sine).to_ruby).to eq('0.5 * 220.hz.sine')
      expect(((220.hz.sine + 1) * 2).softclip.to_ruby).to eq('((220.hz.sine + 1) * 2).softclip')
    end

    it 'gives shared nodes variables' do
      sig = 110.hz.ramp.softclip
      g = sig + sig.delay(100.ms) * 0.5
      expect(g.to_ruby).to eq("fx = 110.hz.ramp.softclip\nfx + fx.delay(100.ms) * 0.5")
    end

    it 'names variables after .named names, else roles, with numeric suffixes' do
      a = 110.hz.ramp.named('Bass Osc')
      b = 220.hz.ramp
      l = 0.5.hz.lfo
      g = a * l + b * l + a * b + b
      expect(g.to_ruby).to eq("bass_osc = 110.hz.ramp.named(\"Bass Osc\")\nosc = 220.hz.ramp\nlfo = 0.5.hz.lfo\nbass_osc * lfo + osc * lfo + bass_osc * osc + osc")

      e = MB::Sound.adsr(0.01, 0.1, 0.5, 0.2)
      s1 = 110.hz.ramp.softclip
      s2 = 220.hz.ramp.softclip
      g = (s1 * e + s2 * e) * s1 * s2
      expect(g.to_ruby.lines.map { |x| x.split(' = ').first }.first(3)).to eq(%w[env fx fx2])
    end

    it 'adds parentheses to bare calls a variable would shadow' do
      MB::Sound.seed(3)
      n = MB::Sound.noise.named('noise')
      g = n * n + MB::Sound.noise.at(0.5)
      code = g.to_ruby
      expect(code).to start_with("noise = noise().named(\"noise\")\n")
      expect(code).to include('noise().at(0.5)')
      ref = render(g, buffers: 2)
      MB::Sound.seed(3)
      expect(RecipeHelpers.max_diff(ref, render(rebuild(code), buffers: 2))).to eq(0)
    end

    it 'prints live values of constants' do
      c = 0.5.constant
      g = 220.hz.sine * c
      c.constant = 0.8
      expect(g.to_ruby).to eq('220.hz.sine * 0.8.constant')
    end

    it 'prints feedback blocks with their parameter names' do
      g = 220.hz.ramp.feedback { |fb, input| input + fb.delay(5.ms) * 0.8 }
      expect(g.to_ruby).to eq("220.hz.ramp.feedback { |fb, input|\n  input + fb.delay(5.ms) * 0.8\n}")
    end

    it 'prints runtime blocks as their source' do
      g = 220.hz.sine.proc { |x| x * x }
      expect(g.to_ruby).to eq('220.hz.sine.proc { |x| x * x }')
    end

    it 'marks runtime blocks that read variables from the code around them' do
      k = 3
      g = 220.hz.sine.proc { |x| x * k }
      expect(g.to_ruby).to start_with('# FIXME(graph-io): the proc block uses k from the code around it')
    end

    it 'prints drawn seeds' do
      MB::Sound.seed(1)
      n = MB::Sound.noise.at(0.5)
      seed = recipe.call_of(MB::Sound::GraphNode::Recipe.call_of(n).receiver)&.seeds&.first || recipe.call_of(n).seeds&.first
      expect(n.to_ruby(seeds: true)).to match(/\Anoise\(seed: \d+\)\.at\(0\.5\)\z/)
      expect(n.to_ruby).to eq('noise.at(0.5)')
      expect(seed).to be_a(Integer)
    end

    it 'names free inputs, and lists them in a header' do
      recipe.enabled = false
      notes = MB::Sound::Notes.new(midi_path)
      recipe.enabled = true
      code = MB::Sound::GraphNode::Recipe::RubyWriter.new(notes.hz.saw * notes.amp_env).to_s
      expect(code).to start_with("# inputs: midi\n")
      expect(code).to end_with('midi.hz.saw * midi.amp_env')
      expect((notes.hz.saw * notes.gate).to_ruby(inputs: { keys: notes })).to eq("# inputs: keys\nkeys.hz.saw * keys.gate")

      # Notes made by user code print as their constructor
      n2 = MB::Sound::Notes.new(midi_path)
      expect(n2.gate.to_ruby).to eq("Notes.new(#{midi_path.inspect}).gate")
    ensure
      recipe.enabled = true
    end

    it 'prints unrepresentable values as nil with a FIXME' do
      g = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 2, 3]]).softclip
      code = g.to_ruby
      expect(code.lines.first).to eq("# FIXME(graph-io): can't print a Numo::SFloat\n")
      expect(code.lines.last).to eq("ArrayInput.new(data: [nil]).softclip # FIXME(graph-io): can't print a Numo::SFloat")
    end

    it 'prints synth lanes once, with per_voice for values that differ' do
      s = MB::Sound.synth(midi_path, voices: 3, spares: 0) { |v, i| v.hz.saw.filter(:lowpass, cutoff: 500 + 250 * i) * v.amp_env * [0.5, 0.25][i % 2] }
      code = s.to_ruby(inputs: { midi: nil })
      expect(code).to include("cutoff: per_voice(500..1000)")
      expect(code).to include('* per_voice(0.5, 0.25)')
      expect(code.scan('synth(').length).to eq(1)
    end

    it 'prints with the console ruby command' do
      expect { MB::Sound.ruby(220.hz.ramp.softclip) }.to output("220.hz.ramp.softclip\n").to_stdout
      expect { MB::Sound.ruby([220.hz.ramp, 330.hz.sine]) }.to output("[220.hz.ramp, 330.hz.sine]\n").to_stdout
    end
  end

  describe 'round trips' do
    # The research prototype's demo graphs
    it 'rebuilds a shared filter and delay chain' do
      round_trip {
        lfo = 0.3.hz.lfo.at(200..2000)
        sig = 110.hz.ramp.filter(:lowpass, cutoff: lfo, quality: 4).softclip
        (sig + sig.delay(250.ms) * 0.5).named('out')
      }
    end

    it 'rebuilds bin/synths/fm_bass.rb' do
      load File.expand_path('../../../../../bin/synths/fm_bass.rb', __dir__) unless MB::Sound.respond_to?(:fm_bass)
      code = round_trip(inputs: -> { { midi: MB::Sound::Notes.new(midi_path) } }, buffers: 100) { |i| MB::Sound.fm_bass(i[:midi], oversample: 1) }
      expect(code).to include('  base = v.hz.glide(100.ms)')
      expect(code).to include('(fx + fx.delay(100.ms)) * 13.db')
    end

    it 'rebuilds a Karplus-Strong feedback loop' do
      code = round_trip {
        exc = (MB::Sound.noise.at(0.5) * MB::Sound.adsr(0, 0, 1, 0, hold: 220.hz.period)).and_then(0.constant)
        exc.feedback { |fb, input|
          d = (fb + input).delay(220.hz.period, smoothing: false)
          ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 880, quality: 0.5**0.5)
        }
      }
      expect(code).to include('  d = (fb + input).delay(')
    end

    it 'rebuilds a stereo bundle through per-channel calls' do
      code = round_trip { MB::Sound.stereo(220.hz.ramp, 330.hz.square).filter(:lowpass, cutoff: 1200, quality: 2).softclip }
      expect(code).to eq('stereo(220.hz.ramp, 330.hz.square).filter(:lowpass, cutoff: 1200, quality: 2).softclip')
    end

    it 'rebuilds per_channel and per_voice values' do
      round_trip { 110.hz.ramp.stereo.filter(:lowpass, cutoff: MB::Sound.per_channel(500..900)).delay(MB::Sound.per_channel(10.ms, 13.ms)) }
      round_trip(inputs: -> { { midi: MB::Sound::Notes.new(midi_path) } }) { |i|
        MB::Sound.synth(i[:midi], voices: 3) { |v| (v.hz.transpose(MB::Sound.per_voice(-0.1..0.1)).saw * v.amp_env).pan(MB::Sound.per_voice(-0.5, 0.5)) }
      }
    end

    it 'rebuilds noise and random phases inside synth lanes from the synth seed' do
      code = round_trip(inputs: -> { { midi: MB::Sound::Notes.new(midi_path) } }) { |i|
        MB::Sound.synth(i[:midi], voices: 2) { |v| (MB::Sound.noise * 0.1 + v.hz.saw.rnd) * v.amp_env }
      }
      expect(code).to match(/synth\(midi, voices: 2, seed: \d+\)/)
    end

    # Lanes run in MB::Sound.with_seed: noises made in one order and used in
    # the other must still print in creation order (bin/synths/pluck.rb)
    it 'keeps seed-drawing nodes in synth lanes in creation order' do
      code = round_trip(inputs: -> { { midi: MB::Sound::Notes.new(midi_path) } }) { |i|
        MB::Sound.synth(i[:midi], voices: 2) { |v|
          n = [MB::Sound.noise, MB::Sound.noise]
          (n[1].filter(:highpass, cutoff: 3000) * 0.3 + n[0].filter(:lowpass, cutoff: 3000) * 0.1) * v.amp_env
        }
      }
      expect(code).not_to include('noise(seed')
    end

    it 'rebuilds unisons, swarms, chorus hiss, and 808 noise from one printed seed each' do
      cases = {
        unison: proc { 220.hz.unison(5, detune: 0.2) { |p, _i| p.ramp.noise(0.1) } },
        swarm: proc { 220.hz.swarm(4, chord: [0, 4, 7], glide: nil, drift: 0.1) { |p, _i| p.ramp } },
        chorus: proc { 110.hz.ramp.at(0.5).chorus(:juno1, hiss: -40) },
        tr808: proc { MB::Sound.tr808(MB::Sound.grid(16, snare: 'x.x.', maracas: 'xxxx', clap: '..x.')) },
      }
      cases.each do |name, build|
        code = round_trip(&build)
        expect(code).to match(/seed: \d+/), "#{name}: #{code}"
        expect(code).not_to include('WARNING'), "#{name}: #{code}"
      end
    end

    it 'rebuilds envelope settings chained after the constructor (and Notes envelopes in synth lanes)' do
      code = round_trip {
        gate = 3.hz.lfo.asquare.at(0..1)
        env = MB::Sound.env(0.01, 0.1, 0.5, 0.1, gate: gate).legato.retrigger(:add).curve(:snappy).shape(release: :s)
        env2 = MB::Sound.adsr(0.01, 0.1, 0.5, 0.1, gate: gate, velocity: 0.4).sensitivity(-12.db..0.db, scale: :db)
          .set_time(:attack, 0.02).set_level(:decay, 0.3)
        dive = MB::Sound.env([[0, 0], [0, 0.01], [-1, 0.05]], release_at: 2, gate: gate, velocity: 0.5).hold_last.no_velocity
        220.hz.saw * env + 330.hz.saw * env2 + dive * 0.1
      }
      expect(code).to include('.legato.retrigger(:add).curve(:snappy).shape(release: :s)')
      expect(code).to include('.sensitivity(-12.db..0.db, scale: :db).set_time(:attack, 0.02).set_level(:decay, 0.3)')
      expect(code).to include('.hold_last.no_velocity')

      code = round_trip(inputs: -> { { midi: MB::Sound::Notes.new(midi_path) } }) { |i|
        MB::Sound.synth(i[:midi], voices: 2) { |v|
          d = v.env([[0, 0], [0, 0.01], [-1, 0.25]], release_at: 2).hold_last.sensitivity(nil)
          v.hz.transpose(d * 12).saw * v.amp_env(0.01, 0.2, 0.5, 0.3).gm(false).legato
        }
      }
      expect(code).to include('.hold_last.sensitivity(nil)')
      expect(code).to include('.gm(false).legato')
    end

    it 'rebuilds delay insert pipelines' do
      code = round_trip {
        220.hz.ramp.delay(30.ms, feedback: 0.5) { |d|
          d.fb { |fb| fb.filter(3000.hz.lowpass).softclip }
          d.wet { |wet| wet.filter(5000.hz.lowpass) }
        }
      }
      expect(code).to include("  d.fb { |fb|\n")
    end

    # Every graph the graph sweep builds, where representable
    describe 'graph sweep factories' do
      # Factories whose graphs can't print yet, and why
      not_representable = {
        'wavetable sample mode reset' => 'a Wavetable made from samples (P3: assets)',
        'ArrayInput' => 'NArray data (P3: assets)',
        'MixSource (master chain input)' => 'a node class defined in the spec (an input)',
      }.freeze

      # Factories whose graphs print, but with state that isn't graph
      # structure, and why
      state_only = {
        'knob moves (Knob, Knob::Reader: a ramp, a jump, a followed node)' => 'knob moves are performance (turns, in a take), not the graph',
      }.freeze

      GraphSweep.factories.each do |name, factory|
        it "rebuilds #{name}" do
          MB::Sound.seed(1)
          graph = factory.call(GraphSweep::Context.new)
          code = graph.to_ruby(seeds: true)
          if state_only.key?(name)
            expect(code).not_to include('FIXME')
            next
          end
          if not_representable.key?(name)
            expect(code).to match(/FIXME|inputs: input/)
            next
          end
          expect(code).not_to include('FIXME')
          expect(code).not_to start_with('# inputs')

          ref = RecipeHelpers.render(graph, buffers: 6, size: 128)
          MB::Sound.seed(code.include?('MB::Sound.seed') ? 1 : 77)
          got = RecipeHelpers.render(rebuild(code), buffers: 6, size: 128)
          expect(RecipeHelpers.max_diff(ref, got)).to eq(0), code
        end
      end
    end
  end
end
