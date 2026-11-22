RSpec.describe(MB::Sound::GraphNode::LoopPlayer::Restretch) do
  let(:lp) { MB::Sound::GraphNode::LoopPlayer }

  # A held saw chord, one second: 2 beats at 120 BPM
  let(:loop) {
    i = Numo::DFloat.new(48000).seq / 48000
    x = [110.0, 164.8].sum { |f| (1..20).sum { |k| Numo::NMath.sin(i * (2 * Math::PI * f * k)) / k } } * 0.2
    MB::Sound::Sample[Numo::SFloat.cast(x), bpm: 120, beats: 2]
  }

  after { described_class.simulate = nil }

  # +frames+ of +player+ in +size+-frame buffers, the transport moved to
  # +bpm+ after +change+ frames.
  def render(player, transport, frames, change: nil, bpm: nil, size: 800)
    out = []
    done = 0
    while done < frames
      transport.bpm = bpm if change && done == change
      n = [size, frames - done, change && done < change ? change - done : size].min
      out << player.sample(n).dup
      done += n
    end
    SpecBuffers.join(out)
  end

  def player(transport, **stretch)
    lp.new(loop, stretch: { mode: :spectral }.merge(stretch), transport: transport)
  end

  it 'makes stretches at once without a live render thread (offline renders as before)' do
    expect(described_class.background?).to eq(false)
    t = MB::Sound::Sequence::Transport.new(bpm: 120)
    p = player(t)
    expect(described_class).not_to receive(:submit)
    y = render(p, t, 4800, change: 1600, bpm: 100)
    expect(y[1600...4800]).to eq(loop.stretch(1.2, mode: :spectral, wrap: true).data(0)[1920...5120])
  end

  it 'plays what it played, then the interim, then the new stretch, crossfading, when simulated as live' do
    described_class.simulate = { interim: 0.02, full: 0.2 }
    fade = (lp::SWAP_FADE * 48000).round
    a = MB::Sound::Sequence::Transport.new(bpm: 120)
    live = render(player(a), a, 48000, change: 9600, bpm: 100)

    # References: the same timeline through players that make each stretch at once
    described_class.simulate = nil
    b = MB::Sound::Sequence::Transport.new(bpm: 120)
    full = render(player(b), b, 48000, change: 9600, bpm: 100)
    c = MB::Sound::Sequence::Transport.new(bpm: 120)
    sliced = render(lp.new(loop, stretch: lp::SLICE_SLOWER, transport: c), c, 48000, change: 9600, bpm: 100)

    expect(live[0...9600]).to eq(full[0...9600])
    # (the first 0.02 s: the old stretch read at the new speed, no click)
    held = live[9600...10560]
    expect(held).not_to eq(full[9600...10560])
    expect((live[9500...10600].diff).abs.max).to be < 2.5 * (full[0...9600].diff).abs.max
    # (then the slice stretch, then the full stretch, each after its
    # crossfade: taken at the first buffer after its time, 11200 and 19200)
    interim = (11200 + fade)...(9600 + 9600)
    expect(live[interim]).to eq(sliced[interim])
    after = (9600 + 9600 + fade)...48000
    expect(live[after]).to eq(full[after])
    expect((live[19000...22200].diff).abs.max).to be < 2.5 * (full[0...9600].diff).abs.max
  end

  it 'holds without an interim stretch with interim: :hold, and quick stretch modes always hold' do
    described_class.simulate = { interim: 0.0, full: 0.1 }
    a = MB::Sound::Sequence::Transport.new(bpm: 120)
    p = player(a, interim: :hold)
    expect(described_class).to receive(:submit).once.and_call_original # (the full stretch only)
    render(p, a, 9600, change: 4800, bpm: 100)
    expect(lp.interim_for(mode: :slice)).to eq(:hold)
    expect(lp.interim_for(mode: :spectral)).to eq(:slice)
    expect(lp.interim_for(mode: :spectral, interim: :coarse)).to eq(:coarse)
    expect { lp.interim_for(mode: :spectral, interim: :wobble) }.to raise_error(ArgumentError, /interim: is one of/)
  end

  it 'makes stretches off a realtime Session\'s render thread' do
    t = MB::Sound::Sequence::Transport.new(bpm: 120)
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: :virtual), transport: t, channels: 1, realtime: true)
    threads = []
    allow_any_instance_of(described_class::Job).to receive(:run).and_wrap_original { |m, *a|
      threads << Thread.current
      m.call(*a)
    }
    s.add(player(t), name: :x)
    s.ensure_running
    s.output.consume(0.1)
    before = described_class.stats[:full][:jobs]
    MB::Sound::Session.with_context(session: s) { MB::Sound.tempo(100) }
    deadline = MB::U.clock_now + 30
    s.output.consume(0.05) until described_class.stats[:full][:jobs] > before || MB::U.clock_now > deadline
    expect(threads).not_to be_empty
    expect(threads).not_to include(s.render_thread)
    expect(threads.map(&:name).uniq).to all(start_with('MB::Sound restretch'))
  ensure
    s&.close
    MB::Sound.rewind
  end
end
