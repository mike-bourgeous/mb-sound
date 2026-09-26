RSpec.describe(MB::Sound::Session::Master) do
  # 120 BPM at 48kHz: a bar is 96000 frames.
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:raise_errors) { true }
  let(:session) { MB::Sound::Session.new(output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: raise_errors) }

  after { session.close }

  # Renders +frames+ frames (in 800-frame buffers) and returns both channels.
  def run(frames)
    Array.new(frames / 800) { session.process_buffer.map(&:dup) }.transpose.map { |c| c.reduce(:concatenate) }
  end

  def chains
    session.instance_variable_get(:@master_chains)
  end

  it 'passes the mix through unchanged with no master chain' do
    session.add([1.constant, 2.constant])
    expect(run(800).map { |c| c[0] }).to eq([1, 2])
    expect(session.master_info).to eq('bypass')
    expect(session.master_active?).to eq(false)
  end

  describe 'blocks' do
    before { session.add([1.constant, 2.constant]) }

    it 'calls a one-parameter block once per channel' do
      calls = 0
      session.master { |mix| calls += 1; mix * 10 }
      expect(calls).to eq(2)
      expect(run(800).map { |c| c[0] }).to eq([10, 20])
      expect(session.master_active?).to eq(true)
    end

    it 'gives every channel to a block with one parameter per channel' do
      session.master { |l, r| [r, l] }
      expect(run(800).map { |c| c[0] }).to eq([2, 1])
    end

    it 'gives every channel to a splat block' do
      session.master { |*ch| ch.map { |c| c * 3 } }
      expect(run(800).map { |c| c[0] }).to eq([3, 6])
    end

    it 'plays a single node from a multichannel block on every channel, sampling it once' do
      node = 0.constant
      session.master { |l, r| node = (l + r).named('sum') }
      expect(node).to receive(:sample).once.and_call_original
      expect(run(800).map { |c| c[0] }).to eq([3, 3])
    end

    it 'accepts MultiOutput nodes' do
      session.master { |l, r| l.fdn_reverb(output_channels: 2, dry: 1, wet: 0) }
      expect(run(800).map { |c| c[0].round(5) }).to eq([1, 1])
    end

    it 'rejects blocks with the wrong number of parameters' do
      expect { session.master { |a, b, c| a } }.to raise_error(ArgumentError, /one parameter.*or 2/)
    end

    it 'rejects per-channel blocks that return several channels' do
      expect { session.master { |m| [m, m] } }.to raise_error(ArgumentError, /must return one node.*2 parameters/)
    end

    it 'rejects the wrong number of channels and things that are not nodes' do
      expect { session.master { |l, r| [l, r, l] } }.to raise_error(ArgumentError, /3 channels for a 2-channel/)
      expect { session.master { |m| 5 } }.to raise_error(ArgumentError, /must return a GraphNode/)
    end
  end

  describe 'switching chains' do
    before do
      session.add(1.constant)
      run(1600)
    end

    it 'starts the first chain on the next bar while something is playing' do
      session.master { |m| m * 2 }
      expect(session.master_info).to match(/starts at bar 2/)
      data = run(96000)[0]
      expect(data[94399]).to eq(1)
      expect(data[94400]).to eq(2)
    end

    it 'supports launch points and scheduled start times' do
      session.master(at: :now) { |m| m * 2 }
      expect(run(800)[0][0]).to eq(2)

      session.master(start_time: transport.position + 1000r / 96000) { |m| m * 3 }
      data = run(1600)[0]
      expect(data[999]).to eq(2)
      expect(data[1000]).to eq(3)
    end

    it 'only keeps the latest of several chains waiting to start' do
      session.master { |m| m * 2 }
      session.master { |m| m * 3 }
      expect(chains.length).to eq(2) # the bypass and the chain waiting to start
      expect(run(96000)[0][-1]).to eq(3)
    end

    it 'lets the old chain spill over its tail by default' do
      session.master(at: :now) { |m| m.delay(samples: 4000) }
      run(8000)

      session.master(at: 2400r / 96000 + transport.position) { |m| m * 1 }
      data = run(56000)[0]

      # The delay's tail of the old input plays on top of the new chain
      expect(data[0...2400].to_a.uniq).to eq([1])
      expect(data[2400...6400].to_a.uniq).to eq([2])
      expect(data[6400..].to_a.uniq).to eq([1])

      # The old chain is dropped once it has been quiet for a second
      expect(chains.length).to eq(1)
    end

    it 'crossfades chains with a fade length' do
      session.master(at: :now) { |m| m * 2 }
      run(800)
      session.master(at: :now, fade: 1/4r) { |m| m * 4 }
      data = run(24800)[0]
      expect(data[0]).to be_within(0.001).of(2)
      expect(data[12000]).to be_within(0.001).of(3)
      expect(data[24000..].to_a.uniq).to eq([4])
      expect(chains.length).to eq(1)
    end

    it 'cuts over without a tail given a zero fade' do
      session.master(at: :now) { |m| m.delay(samples: 4000) }
      run(8000)
      session.master(at: :now, fade: 0) { |m| m * 1 }
      expect(run(8000)[0].to_a.uniq).to eq([1])
      expect(chains.length).to eq(1)
    end

    it 'switches back to bypass and forgets finished chains' do
      session.master(at: :now) { |m| m * 2 }
      run(800)
      session.master(at: :now)
      expect(run(800)[0][0]).to eq(1)

      # The old chain is kept until its (silent) tail has been quiet for a second
      run(47200)
      expect(chains.length).to eq(2)
      run(800)
      expect(chains).to be_empty
      expect(session.master_active?).to eq(false)
    end

    it 'cuts over when processing is overloaded' do
      session.instance_variable_set(:@realtime, true)
      allow(session).to receive(:start_thread) # render here, not in a thread
      allow(session).to receive(:process_master).and_wrap_original do |m, *args, **kw|
        session.instance_variable_set(:@load, 0.9)
        m.call(*args, **kw)
      end
      session.master(at: :now) { |m| m.delay(samples: 4000) }
      run(8000)

      expect(session).to receive(:warn).with(/busy \(90%\).*without spillover/)
      session.master(at: :now) { |m| m * 1 }
      expect(run(800)[0].to_a.uniq).to eq([1])
    end
  end

  describe 'tails' do
    it 'keeps processing while idle so tails ring out' do
      session.add(1.constant.for(800 / 48000.0))
      session.master(at: :now) { |m| m.delay(samples: 1600) }
      data = run(4000)[0]
      expect(data[1600...2400].to_a.uniq).to eq([1])
      expect(transport.position).to eq(1600r / 96000)
    end

    it 'caps a spillover tail that never goes quiet' do
      session.add(1.constant)
      session.master(at: :now) { |m| m.delay(samples: 800, feedback: 0.9999, wet: 0.001) }
      run(1600)
      session.master(at: :now) { |m| m * 1 }
      run(48000 * 10)
      expect(chains.length).to eq(2)
      run(48000 * 0.1 + 800)
      expect(chains.length).to eq(1)
    end
  end

  describe 'errors' do
    let(:raise_errors) { false }

    it 'bypasses a chain that raises an error' do
      session.add(1.constant)
      calls = 0
      session.master { |m| m.proc { |d| (calls += 1) > 2 ? raise('broken') : d * 2 } } # 2 channels
      expect(session).to receive(:warn).with(/stopped with an error.*broken/m)
      expect(run(1600)[0].to_a.values_at(0, 800)).to eq([2, 1])
      expect(session.master_active?).to eq(false)
    end

    it 'bypasses a chain that ends' do
      session.add(1.constant)
      session.master { |m| m * 2.constant.for(800 / 48000.0) }
      expect(session).to receive(:warn).with(/master chain ended/)
      expect(run(1600)[0].to_a.values_at(0, 800)).to eq([2, 1])
    end
  end

  describe '#reset_master' do
    it 'rebuilds the chain, clearing tails' do
      session.add(1.constant.for(800 / 48000.0))
      session.master(at: :now) { |m| m.delay(samples: 1600) * 2 }
      run(800)
      session.reset_master
      expect(run(4000)[0].to_a.uniq).to eq([0])
      expect(session.master_info).to start_with('master:')
      expect(chains.length).to eq(1)
    end

    it 'does nothing without a master chain' do
      session.reset_master
      expect(chains).to be_empty
    end
  end

  it 'gives taps the mix after the master chain' do
    seen = nil
    session.add_tap { |mix| seen = mix }
    session.add(1.constant)
    session.master { |m| m * 5 }
    session.process_buffer
    expect(seen.map { |c| c[0] }).to eq([5, 5])
  end

  it 'keeps clips in master chains on the timeline' do
    session.add(1.constant)
    gate = MB::Sound.grid(4, 'x...').loop.gate
    session.master { |m| m * gate }
    data = run(96000)[0]
    expect(data[0]).to eq(1)
    expect(data[24000]).to eq(0)

    # Clips follow seeks
    transport.seek(1 - 800r / 96000)
    expect(run(1600)[0].to_a.values_at(0, 800)).to eq([0, 1])
  end
end
