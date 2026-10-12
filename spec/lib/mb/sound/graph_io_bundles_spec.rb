# Graph-io phase 3: bundles (name.mbg/ with the document and its assets).
require_relative '../../../support/graph_sweep'

RSpec.describe('graph document bundles', :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }
  let(:audio_path) { File.expand_path('../../../test_data/arp_a7.flac', __dir__) }
  let(:midi_path) { File.expand_path('../../../test_data/c_major.mid', __dir__) }
  let(:presets) { File.dirname(tmp_path('presets/x')) }

  before do
    FileUtils.mkdir_p(presets)
    allow(io).to receive(:presets_dir).and_return(presets)
    allow(io).to receive(:user_presets_dir).and_return(presets)
  end

  def render(graph, buffers: 40, size: 512)
    RecipeHelpers.render(graph, buffers: buffers, size: size)
  end

  def stable(path)
    File.read(path).sub(/saved: "[^"]*"/, '').sub(/name: "[^"]*"/, '')
  end

  # A synth reading a MIDI file, a table from a file (Wavetable[path]), the
  # same file named by a String, and a table made in memory
  def graph
    mine = MB::Sound::Wavetable.from_harmonics([1.0, 0.5, 0.33, 0.25, 0.2, 0.0, 0.1], name: 'mine')
    arp = MB::Sound::Wavetable[audio_path]
    MB::Sound.midi_file(midi_path).synth(voices: 2) { |v|
      (v.hz.wavetable(mine) + v.hz.wavetable(arp) * 0.5 + v.hz.transpose(12).wavetable(audio_path) * 0.2) * v.amp_env
    }
  end

  it 'saves a graph that reads files as a bundle with its assets' do
    path = io.save(:tables, graph)
    dir = File.join(presets, 'tables.mbg')
    expect(path).to eq(File.join(dir, 'tables.mbg.rb'))
    expect(Dir.children(File.join(dir, 'assets')).sort).to eq(['arp_a7.flac', 'c_major.mid', 'mine.flac'])
    text = File.read(path)
    sum = Digest::SHA256.file(audio_path).hexdigest
    expect(text).to include(%{asset "assets/arp_a7.flac", sha256: "#{sum}"})
    expect(text).to include('midi_file("assets/c_major.mid").synth(voices: 2)')
    expect(text).to include('sig.wavetable(Wavetable["assets/mine.flac"]) + sig.wavetable(Wavetable["assets/arp_a7.flac"]) * 0.5 + sig.transpose(12).wavetable("assets/arp_a7.flac")')
    expect(File.binread(File.join(dir, 'assets/arp_a7.flac'))).to eq(File.binread(audio_path))
    expect(io.presets[presets]).to eq([:tables])

    # Files copied as they are play the same; tables made in memory are
    # saved as FLAC with their tags (within float32 rounding)
    a = render(graph)
    b = render(MB::Sound.preset(:tables))
    expect(RecipeHelpers.max_diff(a, b)).to be < 1e-6
    expect(b.map { |c| c.abs.max }.max).to be > 0.1

    # A loaded bundle saves the same and plays bit for bit
    again = io.save(:tables2, MB::Sound.preset(:tables))
    expect(stable(again)).to eq(stable(path))
    expect(RecipeHelpers.max_diff(b, render(MB::Sound.preset(:tables2)))).to eq(0)
    expect(MB::Sound.preset(File.join(presets, 'tables2.mbg'))).to be_a(MB::Sound::Synth)
  end

  it 'refuses assets that changed since the bundle was saved' do
    io.save(:tables, graph)
    File.open(File.join(presets, 'tables.mbg/assets/mine.flac'), 'ab') { |f| f.write('x') }
    expect { MB::Sound.preset(:tables) }.to raise_error(io::LoadError, /asset "assets\/mine.flac" doesn't match the document/)
  end

  it 'checks asset lines' do
    expect { io.load(%{asset "a.flac", sha256: "xyz"\n220.hz.ramp}) }.to raise_error(io::LoadError, /64 hex digits/)
    expect { io.load(%{asset :a\n220.hz.ramp}) }.to raise_error(io::LoadError, /asset takes a file name/)
  end

  it 'makes bundles on request, refuses them with bundle: false, and replaces plain documents' do
    plain = io.save(:ramp, 220.hz.ramp)
    expect(plain).to eq(File.join(presets, 'ramp.mbg.rb'))
    bundled = io.save(:ramp, 220.hz.ramp, bundle: true)
    expect(bundled).to eq(File.join(presets, 'ramp.mbg/ramp.mbg.rb'))
    expect(File.exist?(plain)).to eq(false)
    expect(io.save(:ramp, 220.hz.ramp)).to eq(plain)
    expect(File.exist?(File.join(presets, 'ramp.mbg'))).to eq(false)

    expect { io.save(:tables, graph, bundle: false) }.to raise_error(io::DumpError, /reads files \(.*mine.flac.*\), which only a bundle can hold/)

    FileUtils.mkdir_p(File.join(presets, 'mine.mbg'))
    File.write(File.join(presets, 'mine.mbg/notes.txt'), 'mine')
    expect { io.save(:mine, 220.hz.ramp, bundle: true) }.to raise_error(io::DumpError, /holds other files \(notes.txt\)/)
    expect(File.read(File.join(presets, 'mine.mbg/notes.txt'))).to eq('mine')
  end

  it 'keeps document strings guarded after the loader is gone' do
    s = io::FileGuard.register(+'x.flac', io::FileGuard::Context.new(nil, 'doc', nil))
    GC.start
    expect(io::FileGuard.document_string?(s)).to eq(true)
    expect(io::FileGuard.document_string?(s.dup)).to eq(true)
    expect(io::FileGuard.document_string?('x.flac')).to eq(false)
    expect { MB::Sound::Wavetable[s] }.to raise_error(io::FileError, /only documents loaded from a file/)
  end
end
