RSpec.describe('Track hashes in scenes and sections (form-knobs-1)') do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:session) { new_session }
  let(:set) { session.arrangement }

  def new_session(buffer_size = 800)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: buffer_size)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true)
  end

  def render(session, frames, size = 800)
    sizes = Array(size).cycle
    out = []
    done = 0
    while done < frames
      n = [sizes.next, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    SpecBuffers.join(out)
  end

  def within(session, &block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  after { session.close }

  # Track :a plays its knob :"a/energy" (0..1) times 1000 plus its knob
  # :"a/fill" times 10, so one render shows both.
  before do
    @energy = session.knob(:"a/energy", 0, range: 0..1, smooth: 0)
    @fill = session.knob(:"a/fill", 0, range: 0..1, smooth: 0)
    one = MB::Sound::GraphNode::Constant.new(1, sample_rate: 48000)
    set.track(:a, one * @energy * 1000 + one * @fill * 10)
    set.track(:b, MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000))
  end

  it 'spells out a track hash as the knob values a quoted key gives' do
    set.scene(:one, a: { energy: 0.25, fill: 0.5 })
    set.scene(:two, a: :on, "a/energy": 0.25, "a/fill": 0.5)
    expect(set.scenes[:one].values).to eq({ a: :keep, "a/energy": 0.25, "a/fill": 0.5 })
    expect(set.scenes[:two].values).to eq({ a: :on, "a/energy": 0.25, "a/fill": 0.5 })

    set.scene(:three, a: { clip: :on, energy: [1, { over: 1.bar }] }, b: :on)
    expect(set.scenes[:three].values).to eq({ a: :on, "a/energy": [1, { over: 1.bar }], b: :on })

    set.go(:two, on: :now)
    expect(render(session, 800)[-1]).to be_within(1e-9).of(255)
  end

  it 'keeps the track playing when the hash names no clip, even in a full scene' do
    set.scene(:play, a: :on, b: :on)
    set.scene(:knobs_only, a: { energy: 0.5 })
    set.go(:play, on: :now)
    render(session, 800)
    set.go(:knobs_only, on: :now)
    render(session, 96000)
    expect(session.playing_after_queue?(:a)).to eq(true)
    expect(session.playing_after_queue?(:b)).to eq(false)
    expect(render(session, 800)[-1]).to be_within(1e-9).of(500)
  end

  it 'takes a ramp and a moving value like quoted keys' do
    lfo = 1.bar.lfo.square.at(0..1)
    set.scene(:ramp, a: { clip: :on, energy: [1, { over: 1.bar }] })
    set.scene(:moving, a: { energy: lfo })
    set.go(:ramp, on: :now)
    d = render(session, 96000)
    expect(d[47999]).to be_within(1e-6).of(500)
    expect(d[-1]).to be_within(1e-6).of(1000)
    set.go(:moving, on: :now)
    expect(session.knobs[:"a/energy"].value).not_to be_nil
    d = render(session, 96000)
    expect(d.to_a.uniq.length).to be > 1
  end

  it 'suggests the track\'s own knobs for an unknown one' do
    set.scene(:typo, a: { enrgy: 0.5 })
    expect { set.go(:typo) }.to raise_error(ArgumentError, /:a has no knob enrgy \(did you mean energy:\?\) \(its knobs: energy, fill\)/)
    set.scene(:typo2, "a/fil": 0.5)
    expect { set.go(:typo2) }.to raise_error(ArgumentError, /did you mean fill:/)
  end

  it 'refuses a Hash on a knob, keys that are not Symbols, a knob given twice, and clip: in sections' do
    session.knob(:cut, 100, range: 100..8000)
    expect { set.scene(:x, cut: { a: 1 }) }.to raise_error(ArgumentError, /takes a value, not a Hash/)
    expect { set.scene(:x, a: { 'energy' => 1 }) }.to raise_error(ArgumentError, /are Symbols/)
    expect { set.scene(:x, a: { energy: 1 }, "a/energy": 0.5) }.to raise_error(ArgumentError, /given twice/)
    expect {
      within(session) { MB::Sound.flow(play: false) { s 1, a: { clip: :on } } }
    }.to raise_error(ArgumentError, /a section turns knobs/)
    expect {
      within(session) { MB::Sound.flow(play: false) { s 1, a: { enrgy: 1 } } }
    }.to raise_error(ArgumentError, /has no knob enrgy \(did you mean energy:\?\)/)
  end

  it 'sets the track level with level:' do
    set.scene(:quiet, a: { clip: :on, level: 0.5, energy: 1 })
    expect(set.scenes[:quiet].values.keys).to eq([:a, :"a/level", :"a/energy"])
    set.go(:quiet, on: :now)
    render(session, 96000)
    expect(render(session, 800)[-1]).to be_within(1e-6).of(500)
  end

  describe 'over: :section' do
    it 'ramps across the form section that launches the scene, and across a section value' do
      set.scene(:intro, a: { clip: :on, energy: 0 })
      set.scene(:build, a: { energy: [1, { over: :section }] })
      within(session) {
        MB::Sound.flow(on: :now) do
          intro 1
          build 2, a: { fill: [1, { over: :section }] }
          outro 1, scene: false
        end
      }
      d = render(session, 96000 * 4)
      expect(d[96000 - 1]).to eq(0)
      # half way through the 2-bar build: energy and fill at 0.5
      expect(d[96000 + 96000 - 1]).to be_within(1e-3).of(505)
      expect(d[96000 * 3 - 1]).to be_within(1e-6).of(1010)
      expect(within(session) { session.arrangement.playback.form.to_ruby }).to include('build 2, a: { fill: [1, { over: :section }] }')
    end

    it 'ramps a turn to the end of the playing section' do
      set.scene(:intro, a: :on)
      within(session) { MB::Sound.flow(on: :now) { intro 2 } }
      render(session, 96000)
      within(session) { MB::Sound.turn(:a, energy: 1, fill: 1, over: :section) }
      d = render(session, 96000)
      expect(d[47999]).to be_within(1e-3).of(505)
      expect(d[-1]).to be_within(1e-6).of(1010)
    end

    it 'says what works when no section plays' do
      set.scene(:alone, a: { clip: :on, energy: [1, { over: :section }] })
      expect { set.go(:alone, on: :now) }.to raise_error(ArgumentError, /over: :section ramps to the end of the form section.*over: 4/)
      expect { within(session) { MB::Sound.turn(:"a/energy", 1, over: :section) } }.to raise_error(ArgumentError, /no section is playing/)
    end
  end

  describe 'turn with a track and several knobs' do
    it 'turns them as one command, with over: applying to each' do
      within(session) { MB::Sound.bg(:a) }
      within(session) { MB::Sound.turn(:a, energy: 1, fill: 1, over: 1.bar) }
      d = render(session, 96000)
      expect(d[47999]).to be_within(1e-3).of(505)
      expect(d[-1]).to be_within(1e-6).of(1010)
      within(session) { session.undo }
      render(session, 96000)
      expect(@energy.value).to eq(0)
      expect(@fill.value).to eq(0)
    end

    it 'suggests the track\'s knobs for a typo' do
      expect { within(session) { MB::Sound.turn(:a, enrgy: 1, over: 1.bar) } }.to raise_error(ArgumentError, /did you mean energy:/)
    end
  end
end
