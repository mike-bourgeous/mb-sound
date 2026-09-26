RSpec.describe(MB::Sound::Session::ClipSwaps) do
  # 120 BPM at 48kHz: a bar is 96000 frames, an eighth note 12000.
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true) }

  let(:bass) { MB::Sound.seq(MB::Sound::C2, MB::Sound::E2).n8.loop }
  let(:bass2) { MB::Sound.seq(MB::Sound::D2).n4.loop }

  after { session.close }

  # Renders +frames+ frames (in 800-frame buffers) and returns channel 0.
  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  def clips(name)
    session.instance_variable_get(:@players).values.find { |p| p.name == name }.timeline_nodes.map { |n| n.pending_clip || n.clip }
  end

  it 'swaps a clip and clips made from it on the next bar, keeping the graph' do
    session.add(bass.number + bass.transpose(12).number * 1000, name: :bass)
    run(4000)
    expect(session.swap(:bass, bass2)).to eq(2)

    data = run(96000)
    expect(data[96000 - 4000 - 1]).to eq(MB::Sound::E2.number + MB::Sound::E3.number * 1000)
    expect(data[96000 - 4000]).to eq(MB::Sound::D2.number + MB::Sound::D3.number * 1000)
  end

  it 'keeps the state of nodes after the clips' do
    session.add(bass.gate.delay(samples: 1000, smoothing: false), name: :bass)
    run(4000)
    session.swap(:bass, MB::Sound.seq(nil).n1.loop) # silence from the next bar
    data = run(96000)

    # The delay still plays the last 1000 samples of the old clip's gate
    expect(data[(92000...93000)].to_a.uniq).to eq([1])
    expect(data[93000..].to_a.uniq).to eq([0])
  end

  it 'supports launch points and exact start times' do
    session.add(bass.number, name: :bass)
    run(4000)
    session.swap(:bass, bass2, at: :now)
    expect(run(800)[0]).to eq(MB::Sound::D2.number)

    session.swap(:bass, bass, start_time: transport.position + 100r / 96000)
    data = run(800)
    expect(data[99]).to eq(MB::Sound::D2.number)
    expect(data[100]).to eq(MB::Sound::C2.number) # the note under the timeline position
  end

  it 'swaps chosen clips given old => new pairs, including grid kit rows' do
    beat = MB::Sound.grid(16, kick: 'x...', snare: '..x.')
    beat2 = MB::Sound.grid(16, kick: 'xx..', snare: '...x')
    session.add(beat[:kick].loop.gate + beat[:snare].loop.gate * 2 + bass.number * 0, name: :drums)

    expect { session.swap(:drums, bass2) }.to raise_error(ArgumentError, /3 unrelated clips; pass old => new/)
    expect(session.swap(:drums, { beat[:kick] => beat2[:kick] }, at: :now)).to eq(1)
    starts = -> { clips(:drums).map { |c| c.events.map(&:start) } }
    expect(starts.call).to contain_exactly([0, 1/16r], [1/8r], [0, 1/8r])

    # The kick matches through the clip it plays until its pending swap
    expect(session.swap(:drums, { beat => beat2 }, at: :now)).to eq(2)
    expect(starts.call).to contain_exactly([0, 1/16r], [3/16r], [0, 1/8r])
  end

  it 'rebuilds synth voices from a new chord progression' do
    chords = MB::Sound.seq(MB::Sound::A2, MB::Sound::F2, MB::Sound::C3).n1.loop
    session.add(chords.synth(voices: 2) { |v| v.number }, name: :pad)
    session.swap(:pad, MB::Sound.seq(MB::Sound::A2, MB::Sound::C3, MB::Sound::E3, MB::Sound::G3).n1.loop)
    expect(clips(:pad).map { |c| c.events.map(&:value) }).to eq([[45, 52], [48, 55]])
  end

  it 'swaps stopped players, playing the new clip when resumed' do
    session.add(bass.number, name: :bass)
    run(800)
    session.remove(:bass, fade: 0)
    session.swap(:bass, bass2)
    session.resume(:bass, at: :now, fade: 0)
    expect(run(800)[0]).to eq(MB::Sound::D2.number)
  end

  it 'raises errors for unknown players and clips that are not played' do
    expect { session.swap(:nope, bass2) }.to raise_error(ArgumentError, /No background player :nope/)
    session.add(bass.number, name: :bass)
    expect { session.swap(:bass, { bass2 => bass }) }.to raise_error(ArgumentError, /doesn't play any of the clips/)
    expect { session.swap(:bass, 5) }.to raise_error(ArgumentError, /Pass a Clip or a Hash/)

    session.add(1.constant, name: :const)
    expect { session.swap(:const, bass2) }.to raise_error(ArgumentError, /doesn't play any clips/)
  end
end
