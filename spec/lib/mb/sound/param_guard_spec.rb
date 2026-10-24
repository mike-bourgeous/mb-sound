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

  it 'knows the names table it documents' do
    MB::Sound::Param.names.each do |name, entry|
      problems, built = ParamGuard.check(MB::Sound::Param.declare(name, entry[:range].begin))
      expect(problems).to eq([]), "names table #{name}: #{problems.join('; ')}"
      expect(built[:knob]).to eq(true)
    end
  end
end
