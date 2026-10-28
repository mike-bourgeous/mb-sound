require_relative '../../../support/param_guard'

# The param guard over lib/ and presets/ (param-1; bin/ scripts are in
# spec/bin/param_declarations_spec.rb): every declaration builds a help
# line, a knob, and a document line, with its default in range (see
# spec/support/param_guard.rb).
RSpec.describe('param declarations', :aggregate_failures) do
  def guard(where, params)
    counts = { params: 0, knobs: 0, documents: 0 }
    params.each do |param|
      problems, built = ParamGuard.check(param)
      expect(problems).to eq([]), "#{where} #{param.name}: #{problems.join('; ')}"
      counts[:params] += 1
      counts[:knobs] += 1 if built[:knob]
      counts[:documents] += 1 if built[:document]
    end
    counts
  end

  it 'covers every ArgTypes signature' do
    sigs = MB::Sound::ArgTypes::REGISTRY.values.grep(MB::Sound::ArgTypes::Signature)
    expect(sigs).not_to be_empty
    counts = guard('ArgTypes', sigs.flat_map(&:params))
    expect(counts[:params]).to be >= 2
  end

  it 'covers every MIDI::ControlSpec in lib/ (GM controllers, pedals, bends)' do
    specs = ObjectSpace.each_object(MB::Sound::MIDI::ControlSpec).to_a
    expect(specs.length).to be >= 10
    counts = guard('ControlSpec', specs.map(&:param))
    expect(counts[:knobs]).to be >= 10
  end

  it 'covers every ChannelMixer param' do
    classes = ObjectSpace.each_object(Class).select { |c| c < MB::Sound::GraphNode::ChannelMixer }
    params = classes.flat_map { |c| c.params.values }.uniq
    expect(params.length).to be >= 5
    guard('ChannelMixer', params)
  end

  it "covers every genre template's knobs" do
    names = MB::Sound::Genre.names
    expect(names).to include(:dnb, :ambient)
    params = names.flat_map { |n|
      MB::Sound.genre(n).knobs.map { |k, (default, opts)| MB::Sound::GraphNode::Knob::Spec.new(name: k, default: default, **opts).param }
    }
    counts = guard('genre', params)
    expect(counts[:knobs]).to eq(counts[:params])
  end

  it "covers every presets/ document's param and knob lines" do
    root = File.expand_path('../../../../presets', __dir__)
    files = Dir[File.join(root, '*.mbg.rb')] + Dir[File.join(root, '*.mbg', '*.mbg.rb')]
    expect(files.length).to be >= 40
    total = { params: 0, knobs: 0, documents: 0 }
    files.sort.each do |f|
      doc = MB::Sound::GraphIO.parse(f)
      c = guard(File.basename(f), doc.declarations.values)
      total.merge!(c) { |_, a, b| a + b }
    end
    expect(total[:params]).to be >= 60
    expect(total[:documents]).to eq(total[:params])
  end

  it 'covers the knobs written as literals in lib/ and bin/ (song blocks, genres, racks, help)' do
    root = File.expand_path('../../../..', __dir__)
    files = Dir.glob('{lib,bin}/**/*.rb', base: root).sort.map { |f| File.join(root, f) }
    found = ParamGuard.source_knobs(files)
    checked = found.select { |_, param, _| param }
    expect(checked.length).to be >= 40
    checked.each do |where, param, _|
      problems, built = ParamGuard.check(param)
      expect(problems).to eq([]), "#{where} #{param.name}: #{problems.join('; ')}"
      expect(built[:knob]).to eq(true), "#{where}: no knob"
    end
  end

  # omnibus15 (maintainer: "I'd like to specify the unit only once as long
  # as it's not ambiguous or contradictory"): every entry point reads the
  # one unit given, prints it fully typed, and still refuses two units
  it 'reads a unit given once at every entry point (knob, document lines, script options, macros, mixer params, signatures)' do
    want = '(100.hz..8000.hz).at(150.hz)'
    built = {
      declare: MB::Sound::Param.declare(:cut, (100..8000).at(150.hz)),
      keywords: MB::Sound::Param.new(name: :cut, default: 150.hz, range: 100..8000),
      knob: MB::Sound::GraphNode::Knob::Spec.new(name: :cut, default: (100.hz..8000).at(150)).param,
      document: MB::Sound::GraphIO.parse("graph 5, name: :u\nknob :cut, (100..8000).at(150.hz)\n440.hz.sine\n").declarations[:cut],
      script: MB::Sound::ScriptRunner.declare(:synth, :cut, [150.hz, 'cutoff', 100..8000]).param,
      mixer: Class.new(MB::Sound::GraphNode::ChannelMixer) { param :cut, default: 150.hz, range: 100..8000 }.params[:cut],
      signature: MB::Sound::ArgTypes::Param.new(name: :cut, default: 150.hz, range: 100..8000),
    }
    built.each do |where, param|
      expect(param.to_ruby).to include(want), "#{where}: #{param.to_ruby}"
      problems, = ParamGuard.check(param)
      expect(problems).to eq([]), "#{where}: #{problems.join('; ')}"
    end
    allowed = MB::Sound::ScriptRunner.declare(:synth, :cut, [150.hz, 'cutoff', 100..8000]).allowed
    expect(MB::Sound::Param.value_key(allowed)).to eq(MB::Sound::Param.value_key(100.hz..8000.hz))

    # (rack macros and ChannelMixer params build Knob specs and Params as above)
    expect(MB::Sound::Param.declare(:amt, (0.1..1).at(-3.db)).to_ruby).to include('(-20.0.db..0.0.db).at(-3.db)')
    expect { MB::Sound::Param.declare(:amt, (0..1).at(-6.db)) }.to raise_error(MB::Sound::Param::Error, /linear gains, so 0 has no level/)
    expect { MB::Sound::Param.declare(:cut, (100.hz..8000).at(2.seconds)) }.to raise_error(MB::Sound::Param::Error, /frequency \(100\.hz\) and a length in seconds \(2\.seconds\)/)
    expect { MB::Sound::Param.new(name: :cut, default: 150.hz, range: 100..8000, type: :seconds) }.to raise_error(MB::Sound::Param::Error, /type: :seconds/)
    expect { MB::Sound::Param.new(name: :cut, default: 150.hz, range: 100..8000, unit: 'Hz') }.to raise_error(MB::Sound::Param::Error, /carries its own unit/)
  end

  it 'knows the names table it documents' do
    MB::Sound::Param.names.each do |name, entry|
      problems, built = ParamGuard.check(MB::Sound::Param.declare(name, entry[:range].begin))
      expect(problems).to eq([]), "names table #{name}: #{problems.join('; ')}"
      expect(built[:knob]).to eq(true)
    end
  end
end
