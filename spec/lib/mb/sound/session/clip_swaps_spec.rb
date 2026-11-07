RSpec.describe(MB::Sound::Session::ClipSwaps) do
  # 120 BPM at 48kHz: a bar is 96000 frames, an eighth note 12000.
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true) }

  let(:bass) { MB::Sound.seq(MB::Sound::C2, MB::Sound::E2).n8.loop }
  let(:bass2) { MB::Sound.seq(MB::Sound::D2).n4.loop }

  after { session.close }

  # Renders +frames+ frames (in 800-frame buffers) and returns channel 0.
  def run(frames)
    SpecBuffers.join(Array.new(frames / 800) { session.process_buffer[0].dup })
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
    session.add(bass.gate.delay(1000.samples, smoothing: false), name: :bass)
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

  it 'swaps a whole Kit by row names: missing rows go silent and come back, new rows warn (omnibus13)' do
    beat = MB::Sound.grid(16, kick: 'x...', snare: '..x.', closed_hat: 'xxxx')
    session.add(beat[:kick].loop.gate + beat[:snare].loop.gate * 2 + beat[:closed_hat].loop.gate * 4, name: :drums)
    starts = -> { clips(:drums).map { |c| c.events.map(&:start) } }

    # (the snare gone; a clap the graph has no voice for; +output+ is a
    # let here, so stderr is caught by hand)
    err = StringIO.new
    old, $stderr = $stderr, err
    begin
      expect(session.swap(:drums, MB::Sound.grid(16, kick: 'xx..', closed_hat: 'x...', clap: 'x...'), at: :now)).to eq(3)
    ensure
      $stderr = old
    end
    expect(err.string).to match(/\Aswap :drums: :clap isn't a row the player plays/)
    expect(starts.call).to contain_exactly([0, 1/16r], [], [0])
    expect(clips(:drums).map(&:looping?)).to eq([true, true, true])

    # The snare comes back from its silent row; the kick matches through its pending swap
    expect(session.swap(:drums, MB::Sound.grid(16, kick: '...x', snare: 'x...', closed_hat: '.x..'), at: :now)).to eq(3)
    expect(starts.call).to contain_exactly([3/16r], [0], [1/16r])

    expect { session.swap(:drums, bass2) }.to raise_error(ArgumentError, /unrelated clips/)
  end

  # (fix-fuzz-1106, SessionFuzz seed 773034: a kit track a flow had
  # switched to a beats clip; the message asked for old_kit => new_kit
  # pairs, which find no rows either)
  it 'says what a player plays when a Kit has no rows to swap into' do
    session.add(bass.number, name: :drums)
    expect { session.swap(:drums, MB::Sound.grid(16, kick: 'x...')) }.to raise_error(
      ArgumentError, /\APlayer :drums plays a clip \(.+\), not a grid kit's rows, so a Kit has no rows to swap into: bg it again with a kit/
    )

    MB::Sound::Session.with_context(session: session) do
      MB::Sound.track(:beat) { |kit| MB::Sound.tr808(kit) }
      MB::Sound.bg(:beat, MB::Sound.seq(MB::Sound::C2).n4.loop, on: :now)
    end
    run(800)
    expect { session.swap(:beat, MB::Sound.grid(16, kick: 'x...')) }.to raise_error(ArgumentError, /: `bg :beat, kit` builds the track's patch for the kit's rows/)
  end

  it 'swaps in a transformed Kit (parity-1: Kits transform per row)' do
    beat = MB::Sound.grid(16, kick: 'x...', snare: '..x.', closed_hat: 'xx..').loop
    session.add(beat[:kick].gate + beat[:snare].gate * 2 + beat[:closed_hat].gate * 4, name: :drums)
    starts = -> { clips(:drums).map { |c| c.events.map(&:start) } }

    expect(session.swap(:drums, beat.reverse, at: :now)).to eq(3)
    run(800)
    expect(starts.call).to contain_exactly([3/16r], [1/16r], [1/8r, 3/16r])
    expect(session.swap(:drums, beat.rotate(1.n16), at: :now)).to eq(3)
    run(800)
    expect(starts.call).to contain_exactly([1/16r], [3/16r], [1/16r, 1/8r])
    expect(session.swap(:drums, beat.shift(1.n8), at: :now)).to eq(3)
    run(800)
    expect(starts.call).to contain_exactly([1/8r], [], [1/8r, 3/16r])
    expect(clips(:drums).map(&:looping?)).to eq([true, true, true])
  end

  it 'swaps the clip of a synth, whose voices play the new chords' do
    chords = MB::Sound.seq(MB::Sound::A2, MB::Sound::F2, MB::Sound::C3).n1.loop
    session.add(chords.synth(voices: 2) { |v| v.number * v.gate }, name: :pad)
    run(4000)
    four = MB::Sound.seq(MB::Sound::A2, MB::Sound::C3, MB::Sound::E3, MB::Sound::G3).n1.loop
    expect(session.swap(:pad, four)).to eq(1)
    expect(session.queued(:pad).map(&:kind)).to eq([:swap]) # waits in the change queue until the bar

    data = run(96000)
    expect(clips(:pad)).to eq([four])
    expect(data[96000 - 4000 - 1]).to eq(MB::Sound::A2.number)
    expect(data[96000 - 4000]).to eq(MB::Sound::C3.number) # bar 2 of the new loop, in phase
  end

  it 'starts launch-aligned loops at their beginning on the swap, keeping that anchor through seeks' do
    triplet = MB::Sound.seq(MB::Sound::D2, MB::Sound::F2, MB::Sound::A2).n4 # 3 beats
    session.add(bass.number, name: :bass)
    run(4000)
    session.swap(:bass, triplet.loop(align: :launch))
    data = run(96000)
    expect(data[96000 - 4000 - 1]).to eq(MB::Sound::E2.number)
    expect(data[96000 - 4000]).to eq(MB::Sound::D2.number) # a timeline loop would be on F2

    # Seeking a beat past the swap's bar line plays the F2, and before it
    # the cycle leading up to the swap (A2 in the beat before)
    transport.seek(5/4r)
    expect(run(800)[0]).to eq(MB::Sound::F2.number)
    transport.seek(3/4r)
    expect(run(800)[0]).to eq(MB::Sound::A2.number)
  end

  it 'swaps stopped players, playing the new clip when resumed' do
    session.add(bass.number, name: :bass)
    run(800)
    session.remove(:bass, fade: 0)
    session.swap(:bass, bass2)
    session.resume(:bass, at: :now, fade: 0)
    expect(run(800)[0]).to eq(MB::Sound::D2.number)
  end

  # (fix-808-fuzz, SessionFuzz seed 28 of tempo-2: changes land at the
  # start of their span, so at 367 frames a swap landing on the frame a fade
  # ended saw the faded player neither playing nor stopped yet, and was
  # lost; at 800 the fade ended with a buffer and the swap found it stopped)
  [800, 367].each do |size|
    it "swaps a player whose fade-out ends on the swap's frame as the stopped player at #{size}-frame buffers" do
      s = MB::Sound::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: size, realtime: false, raise_errors: true)
      s.add(bass.number, name: :bass)
      s.remove(:bass, fade: 1/4r, time: 1/4r) # beat 2, ending on beat 3 (frame 48000)
      s.swap(:bass, bass2, start_time: 1/2r)
      s.process_buffer while s.frame < 48000 + size
      expect(s.stopped.keys).to eq([:bass])

      s.resume(:bass, at: :now, fade: 0)
      expect(s.process_buffer[0][-1]).to eq(MB::Sound::D2.number)
    ensure
      s&.close
    end
  end

  # (fix-bufsize-1107, SessionFuzz seed 394532: a scheduled block run ahead
  # of bar 2 swapped the launch queued there at 800 frames, and at 367 found
  # the stopped player still kept, whose clip it doesn't play: the swap
  # raised and the track built its patch again)
  it 'swaps the clips of a launch queued to land by the swap, not the stopped or current player it replaces' do
    queued = MB::Sound.seq(MB::Sound::G2).n4.loop
    session.add(bass.number, name: :bass)
    session.add(bass.number * 0, name: :x)
    run(800)
    session.remove(:bass, fade: 0)
    run(800)
    expect(session.stopped.keys).to eq([:bass])

    session.add(queued.number, name: :bass, start_time: 1r)
    expect(session.swap(:bass, { queued => bass2 }, start_time: 1r)).to eq(1)
    session.add(queued.number * 1000, name: :x, start_time: 1r) # (:x plays bass until then)
    expect(session.swap(:x, { queued => bass2 }, start_time: 1r)).to eq(1)
    expect { session.swap(:x, { queued => bass2 }, start_time: 1/2r) }.to raise_error(ArgumentError, /doesn't play any of the clips/)

    data = run(96_000)
    expect(data[96_000 - 1600 - 1]).to eq(0)
    expect(data[96_000 - 1600]).to eq(MB::Sound::D2.number) # (:x fades in over the declick)
    expect(data[96_000 - 1600 + 1000]).to eq(MB::Sound::D2.number * 1001)
  end

  it 'raises errors for unknown players and clips that are not played' do
    expect { session.swap(:nope, bass2) }.to raise_error(ArgumentError, /No background player :nope/)
    session.add(bass.number, name: :bass)
    expect { session.swap(:bass, { bass2 => bass }) }.to raise_error(ArgumentError, /doesn't play any of the clips/)
    expect { session.swap(:bass, 5) }.to raise_error(ArgumentError, /Pass a Clip, a Kit, or a Hash/)

    session.add(1.constant, name: :const)
    expect { session.swap(:const, bass2) }.to raise_error(ArgumentError, /doesn't play any clips/)
  end
  it "raises ClipsOver for a one-shot clip that has ended or will have when the swap lands (omnibus15)" do
    one = MB::Sound.seq(MB::Sound::C2).n4
    session.add(one.synth(voices: 1) { |v| v.number * v.env(0, 0, 1, 1.0).no_velocity }, name: :bass)
    run(4000)
    # (still playing, but over by the next bar)
    expect { session.swap(:bass, bass2) }.to raise_error(MB::Sound::Session::ClipsOver, /:bass's clip has ended.*bg :bass/)
    # (a swap before it ends is heard)
    expect(session.swap(:bass, bass2, start_time: transport.position + 1/8r)).to eq(1)
    expect(session.clips_over_by?(:bass, transport.position + 1)).to eq(false) # (a swap is queued)

    run(48000)
    expect(run(800)[400]).to be_within(1e-6).of(MB::Sound::D2.number)
  end
end
