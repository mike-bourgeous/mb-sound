# The init voice (sound-design-2): the blank patch `design :lead` starts
# from.  Two morphing wavetable oscillators, FM/AM/sync each off by default
# (sync read while the voice builds: no synced kernel while it's off), lp4
# with its envelope, an amp ADSR, glide; every number a param.
RSpec.describe('bin/synths/init_voice.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/init_voice.rb', __dir__) }

  after { MB::Sound.rewind }

  def notes = patch_notes([57, 0, 0.3, 1.0], [60, 0.3, 0.6, 0.8], [64, 0.6, 1.0, 1.0])

  def render(graph, buffers = 60)
    SpecBuffers.join((0...buffers).map { graph.sample(800)&.dup }.compact)
  end

  def synced_tones(graph)
    graph.graph.select { |n| n.is_a?(MB::Sound::Tone) && n.sync_source }
  end

  it 'builds no synced oscillator while sync is off, and one per voice when it is on' do
    off = MB::Sound.init_voice(notes, voices: 2)
    render(off, 2)
    expect(synced_tones(off)).to be_empty
    on = MB::Sound.init_voice(notes, voices: 2, sync: 1)
    render(on, 2)
    osc2s = on.graph.select { |n| n.is_a?(MB::Sound::Tone) && n.named? && n.graph_node_name == 'osc2' }
    expect(osc2s.length).to be >= 2
    expect(synced_tones(on)).to match_array(osc2s)
    # (the switch shows as each OSC2's sync param, on or off)
    osc2 = off.graph.find { |n| n.is_a?(MB::Sound::Tone) && n.named? && n.graph_node_name == 'osc2' }
    expect(osc2.param_info[:sync].value).to eq(0)
  end

  it 'plays FM and AM only when turned up: 0 is exactly the plain mix' do
    plain = render(MB::Sound.init_voice(notes, voices: 3))
    expect(plain.abs.max).to be > 0.05
    fm = render(MB::Sound.init_voice(notes, voices: 3, fm: 1.5))
    am = render(MB::Sound.init_voice(notes, voices: 3, am: 1))
    expect((fm - plain).abs.max).to be > 0.01
    expect((am - plain).abs.max).to be > 0.01
    expect(render(MB::Sound.init_voice(notes, voices: 3, fm: 0, am: 0))).to eq(plain)
  end

  it 'morphs sine, triangle, square, saw with level kept (the library\'s :basic_norm scan)' do
    rms = [0.0, 1 / 3.0, 2 / 3.0, 1.0].map { |w|
      d = render(MB::Sound.init_voice(notes, voices: 3, wave1: w, wave2: w, cutoff: 20000.0, fenv: 0.0), 40)
      Math.sqrt((d**2).mean)
    }
    db = rms.map { |r| 20 * Math.log10(r) }
    expect(db.max - db.min).to be < 4.5
  end

  it 'saves every knob as a param of the init preset, sync as a stepped switch' do
    doc = MB::Sound::GraphIO.parse(File.expand_path('../../../presets/init.mbg.rb', __dir__))
    expect(doc.params.keys).to eq(MB::Sound::INIT_KNOBS.keys)
    expect(doc.declarations[:sync].range).to eq(0..1)
    expect(doc.declarations[:cutoff].default).to eq(1200.0)
  end
end
