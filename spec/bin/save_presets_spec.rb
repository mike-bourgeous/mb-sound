require 'shellwords'

# The presets that come with mb-sound (presets/, bin/save_presets.rb): each
# loads from its document and plays bit for bit like the script patch or
# effect method it was saved from.
require File.expand_path('../../bin/save_presets.rb', __dir__)

RSpec.describe('bin/save_presets.rb') do
  before(:all) do
    %w[dnb jungle ambient funk electric_pianos sq80_voice].each { |s| require File.expand_path("../../bin/synths/#{s}.rb", __dir__) }
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
      wave = script.end_with?('wave_voices.rb')
      expect(doc.description).to eq(MB::Sound.public_send(:"#{File.basename(script, '.rb')}_description", patch))
      if script.end_with?('sq80_voice.rb')
        expect(doc.description).to include("from #{script}", 'sq80-lib-1')
      elsif wave
        expect(doc.description).to include("from #{script}", 'research-sq80 prototype', 'protos-1')
      else
        expect(doc.description).to include("from #{script}", 'persona panel experiment')
      end

      # Drum kits play GM drum notes (kick, hat, snare, shaker, ride, conga)
      midi = -> {
        if [:drums, :perc, :beat].include?(patch)
          MB::Sound::Notes.new(patch_notes([36, 0, 0.1, 1.0], [42, 0.1, 0.2], [38, 0.2, 0.3], [70, 0.3, 0.4], [51, 0.4, 0.5], [64, 0.5, 0.6]))
        else
          MB::Sound::Notes.new(midi_file)
        end
      }

      MB::Sound.seed(MB::Sound::Internal.default_seed) # as the script saw it
      direct =
        if wave
          MB::Sound.wave_voice(midi.(), patch)
        else
          MB::Sound.public_send("#{File.basename(script, '.rb')}_patch", midi.(), patch)
        end
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

  MB::Sound::LIBRARY_PRESET_RACKS.each do |name, (script, method, _description)|
    it "loads the #{name} rack document and plays it like #{File.basename(script)}'s rack" do
      require File.expand_path("../../#{script}", __dir__)
      file = MB::Sound.library_preset_file(io.library_presets_dir, name)
      doc = io.parse(file)
      expect(doc).to be_rack
      expect(doc.description).to start_with("Rack :#{name} from #{script}")

      session = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false))
      begin
        MB::Sound::Session.with_context(session: session) do
          source = -> { 110.hz.saw.at(0.3) * MB::Sound.adsr(0.01, 0.2, 0, 0.1) }
          direct = source.().then(&MB::Sound.public_send(method, :"#{name}_direct"))
          rack = io.load(file)
          expect(rack).to be_a(MB::Sound::Rack)
          expect(render_buffers(source.().then(&rack), 40)).to eq(render_buffers(direct, 40))
        end
      ensure
        session.close
      end
    end
  end

  MB::Sound::LIBRARY_PRESET_SETS.each do |name, (script, setup, form, form_options, _description)|
    # (the longer flows in the slow tier, SLOW=1; night_bus stays in the everyday run)
    it "loads the #{name} set document and plays its flow like #{File.basename(script)}", slow: name != :night_bus do
      require File.expand_path("../../#{script}", __dir__)
      file = MB::Sound.library_preset_file(io.library_presets_dir, name)
      expect(io.parse(file).kind).to eq(:set)

      bar = 0
      play = ->(&build) {
        s = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
        begin
          MB::Sound.seed(3)
          f = MB::Sound::Session.with_context(session: s) { build.call(s) }
          MB::Sound::Session.with_context(session: s) { MB::Sound.play_form(f, warm_up: false) }
          bar = (s.transport.bar_length / s.transport.whole_notes_per_second * 48000).round
          out = SpecBuffers.join((0...(bar * 8 / 800)).map { s.process_buffer(800)[0].dup }) # (8 bars: tunnel_vision at 12 took 6.65 s on the runner, over the 6 s example budget)
          [s.arrangement.tracks.keys, s.arrangement.scenes.keys, s.knobs.keys, out]
        ensure
          s.close
        end
      }
      tracks, scenes, knobs, direct = play.() { MB::Sound.public_send(setup); MB::Sound.public_send(form, **form_options) }
      ltracks, lscenes, lknobs, loaded = play.() { |s| io.load(file, session: s).form }
      expect([ltracks, lscenes, lknobs]).to eq([tracks, scenes, knobs])

      # The same music, bar by bar (noise and other drawn seeds differ)
      rms = ->(x) { (0...(x.length / bar)).map { |i| Math.sqrt((x[(i * bar)...((i + 1) * bar)]**2).mean) } }
      expect(rms.(loaded).zip(rms.(direct))).to all(satisfy { |a, b| (a - b).abs <= 0.08 * b + 1e-4 })
      expect(rms.(loaded).max).to be > 0.01
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
