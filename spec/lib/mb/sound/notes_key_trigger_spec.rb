RSpec.describe(MB::Sound::Notes::KeyTrigger, :check_shared) do
  let(:ev) { MB::Sound::MIDI::Event }

  def notes_for(*events)
    MB::Sound::Notes.new(MIDIListSource.new(events, ev.cc(99, 0, time: 1000r)))
  end

  # Mono: 69 at 0, struck again at 0.21 s while held (both released at 0.3
  # s, a 50 ms release), then a fresh 69 at 0.71 s.  The half sample keeps
  # the strikes off sample boundaries.
  let(:events) {
    [
      ev.note_on(69, 1.0), ev.note_on(69, 0.5, time: 21/100r + 1/96000r),
      ev.note_off(69, time: 3/10r), ev.note_off(69, time: 3/10r),
      ev.note_on(69, 1.0, time: 71/100r + 1/96000r), ev.note_off(69, time: 8/10r),
    ]
  }
  let(:restrike) { 10080 }  # the sample of the re-strike
  let(:fresh) { 34080 }    # the sample of the fresh note

  # Renders a key-synced sine times an amp_env with retrigger +mode+ (the
  # envelope first if +env_first+), and the same with a free sine.  Returns
  # [keyed, free, the Notes].
  def render(mode, env_first: false, buffer: 480, buffers: 100)
    out = [:keyed, :free].map { |kind|
      v = notes_for(*events)
      env = v.amp_env(0.001, 1, 0.5, 0.05).retrigger(mode)
      tone = kind == :keyed ? v.hz.sine : v.hz.sine.free
      graph = env_first ? env * tone : tone * env
      [buffers.times.map { graph.sample(buffer).dup }.reduce(:concatenate), v]
    }
    [out[0][0], out[1][0], out[0][1]]
  end

  it 'leaves out mono re-strikes of a sounding :add voice, so the phase continues' do
    keyed, free = render(:add)
    expect(keyed[0...fresh].to_a).to eq(free[0...fresh].to_a)

    # A fresh note after the release still resets
    expect((keyed[fresh...fresh + 200] - free[fresh...fresh + 200]).abs.max).to be > 0.1
  end

  it 'still resets at re-strikes with :restart envelopes' do
    keyed, free = render(:restart)
    expect(keyed[0...restrike].to_a).to eq(free[0...restrike].to_a)
    expect((keyed[restrike...restrike + 200] - free[restrike...restrike + 200]).abs.max).to be > 0.1
  end

  it 'gives the same samples whether the envelope or the tone is sampled first, and at other buffer sizes' do
    [:add, :restart].each do |mode|
      a = render(mode)[0]
      expect(render(mode, env_first: true)[0].to_a).to eq(a.to_a), mode.to_s

      # Tones differ by rounding (~1e-11) between buffer sizes; a reset more
      # or less would differ by far more
      [[96, 500], [800, 60]].each do |buffer, buffers|
        expect((render(mode, buffer: buffer, buffers: buffers)[0] - a).abs.max).to be < 1e-9, "#{mode} #{buffer}"
      end
    end
  end

  it 'keeps every note-on in #trigger, and leaves the re-strike out of #key_trigger' do
    v = notes_for(*events)
    env = v.amp_env(0.001, 1, 0.5, 0.05).retrigger(:add)
    trig = v.trigger
    key = v.key_trigger
    expect(v.key_sync_trigger).to equal(key)
    t = []
    k = []
    100.times do
      t << trig.sample(480).dup
      k << key.sample(480).dup
      env.sample(480)
    end
    t = t.reduce(:concatenate)
    k = k.reduce(:concatenate)
    expect(t.to_a.each_index.select { |i| t[i] > 0 }).to eq([0, restrike, fresh])
    expect(k.to_a.each_index.select { |i| k[i] > 0 }).to eq([0, fresh])
    expect(k[0]).to eq(1.0)
  end

  it 'is the same as #trigger without envelopes, or before any envelope is :add' do
    v = notes_for(*events)
    trig = v.trigger
    key = v.key_trigger
    out = 100.times.map { [trig.sample(480).dup, key.sample(480).dup] }.transpose.map { |l| l.reduce(:concatenate) }
    expect(out[1].to_a).to eq(out[0].to_a)
  end

  it 'keeps resetting at every note-on with an explicit reset(v.trigger)' do
    v = notes_for(*events)
    env = v.amp_env(0.001, 1, 0.5, 0.05).retrigger(:add)
    graph = v.hz.sine.reset(v.trigger) * env
    keyed = 100.times.map { graph.sample(480).dup }.reduce(:concatenate)
    free = render(:add)[1]
    expect((keyed[restrike...restrike + 200] - free[restrike...restrike + 200]).abs.max).to be > 0.1
  end
end
