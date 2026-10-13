require 'shellwords'

# The presets that come with mb-sound (presets/, bin/save_presets.rb): each
# loads from its document and plays bit for bit like the script patch or
# effect method it was saved from.
require File.expand_path('../../bin/save_presets.rb', __dir__)

RSpec.describe('bin/save_presets.rb') do
  before(:all) do
    %w[dnb jungle ambient funk electric_pianos].each { |s| require File.expand_path("../../bin/synths/#{s}.rb", __dir__) }
  end

  after { MB::Sound.rewind }

  let(:io) { MB::Sound::GraphIO }
  let(:midi_file) { MB::Sound::LIBRARY_PRESET_MIDI }

  # Renders +graph+ for +buffers+ buffers of 800 samples, every channel.
  def render_buffers(graph, buffers)
    outs = patch_outputs(graph)
    (0...buffers).map { outs.map { |o| o.sample(800)&.dup } }
  end

  it 'has every preset in presets/, and nothing else' do
    names = io.presets[io.library_presets_dir]
    expect(names.sort).to eq(MB::Sound.library_preset_names.sort)
  end

  MB::Sound::LIBRARY_PRESET_PATCHES.each do |name, (script, patch, *_extra)|
    it "loads #{name} and plays it like #{File.basename(script)} -p #{patch}" do
      file = MB::Sound.library_preset_file(io.library_presets_dir, name)
      doc = io.parse(file)
      expect(doc.inputs).to eq([:midi])
      expect(doc.kind).to eq(:synth)
      expect(doc.description).to eq(MB::Sound.public_send(:"#{File.basename(script, '.rb')}_description", patch))
      expect(doc.description).to include("from #{script}", 'persona panel experiment')

      # Drum kits play GM drum notes (kick, hat, snare, shaker, ride, conga)
      midi = -> {
        if [:drums, :perc, :beat].include?(patch)
          MB::Sound::Notes.new(patch_notes([36, 0, 0.1, 1.0], [42, 0.1, 0.2], [38, 0.2, 0.3], [70, 0.3, 0.4], [51, 0.4, 0.5], [64, 0.5, 0.6]))
        else
          MB::Sound::Notes.new(midi_file)
        end
      }

      MB::Sound.seed(MB::Sound::Internal.default_seed) # as the script saw it
      direct = MB::Sound.public_send("#{File.basename(script, '.rb')}_patch", midi.(), patch)
      expected = render_buffers(direct, 40)

      loaded = io.load(file, inputs: { midi: midi.() })
      got = render_buffers(loaded, 40)
      expect(got.length).to eq(expected.length)
      expect(got).to eq(expected)
      expect(expected.flatten.compact.map { |b| b.abs.max }.max).to be > 0
    end
  end

  MB::Sound::LIBRARY_PRESET_EFFECTS.each do |name, (_script, params, builder)|
    it "loads the #{name} effect and plays it like its method" do
      file = MB::Sound.library_preset_file(io.library_presets_dir, name)
      doc = io.parse(file)
      expect(doc.inputs).to eq([:input])
      expect(doc.params.keys).to eq(params.keys)
      expect(doc.description).to start_with("Effect :#{name} from bin/synths/").and include('first made by')

      source = -> { 110.hz.saw.at(0.3) * MB::Sound.adsr(0.01, 0.2, 0, 0.1) }
      direct = MB::Sound.with_seed(0) { builder.call(source.(), params.transform_values { |p| p[:value].constant }) }
      loaded = io.load(file, inputs: { input: source.() })
      expect(render_buffers(loaded, 40)).to eq(render_buffers(direct, 40))
    end
  end

  it 'loads presets by name with `preset`, taking params' do
    g = MB::Sound.preset(:dnb_reese, midi: MB::Sound::Notes.new(midi_file), cutoff: 600)
    expect(io.document_of(g)[:cutoff]).to eq(600)
    expect(render_buffers(g, 10).flatten.compact.map { |b| b.abs.max }.max).to be > 0
  end

  it 'finds the presets up to date (a real run of the script)' do
    text = `bin/save_presets.rb --check ambient_tape 2>&1`
    expect($?).to be_success, text
    expect(text).to include('1 preset up to date')
  end
end
