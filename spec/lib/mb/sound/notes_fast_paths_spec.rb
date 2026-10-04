# Null tests for the fast paths of Notes nodes, NoteEnvelopes, and Synth
# (MB::Sound::Notes.fast_paths): the same synth must give exactly the same
# samples with them on and off.
RSpec.describe('MB::Sound::Notes fast paths', :check_shared) do
  around do |example|
    old = MB::Sound::Notes.fast_paths
    example.run
  ensure
    MB::Sound::Notes.fast_paths = old
  end

  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 150) }

  # A patch using every kind of Notes node: note nodes, channel nodes,
  # glide, vibrato (with its fade-in), envelopes with GM scaling and lift,
  # cutoff and quality.
  let(:patch) {
    ->(v, i) {
      pitch = v.hz.glide(0.03).vibrato(5, depth: 0.3, delay: 0.1)
      tone = pitch.saw * v.amp_env(0.01, 0.1, 0.6, 0.2) +
        v.hz.transpose(7).square * v.env(0, 0.2, 0.3, 0.1, lift: true) * v.velocity * 0.5
      filtered = tone.filter(:lowpass, cutoff: v.cutoff(800), quality: v.quality(2))
      extras = v.gate * 0.01 + v.trigger * 0.1 + v.choke * 0.2 + v.number * 0.001 + v.lift * 0.01
      filtered * (1 + v.pressure + v.bend * 0.5 + v.mod) + extras + v.freq * 0.0001
    }
  }

  # Renders a synth from +source+ (made by the block, once per run) with
  # buffers of +sizes+ in turn, for +seconds+.
  def render(fast, seconds:, sizes: [128], voices: 3, spares: 0, &source)
    MB::Sound::Notes.fast_paths = fast
    synth = MB::Sound::Synth.new(source.call, voices: voices, spares: spares, seed: 3, tail: 0, &patch)
    out = []
    total = 0
    i = 0
    while total < seconds * 48000
      buf = synth.sample(sizes[i % sizes.length])
      break if buf.nil?
      out << buf.dup
      total += buf.length
      i += 1
    end
    out.reduce(:concatenate)
  end

  def null_test(**options, &source)
    fast = render(true, **options, &source)
    slow = render(false, **options, &source)
    expect(fast.length).to eq(slow.length)
    expect(fast.abs.max).to be > 0.01
    expect(fast.to_a).to eq(slow.to_a)
  end

  [
    'c_major.mid', 'pitch_bend.mid', 'mod_wheel.mid', 'c2_sustain.mid',
  ].each do |file|
    it "gives the same samples for #{file}" do
      null_test(seconds: 0.8, sizes: [128, 300, 64]) { "spec/test_data/#{file}" }
    end
  end

  it 'gives the same samples with voice stealing, chokes, and at 512 samples' do
    null_test(seconds: 1, sizes: [512], voices: 2, spares: 1) { 'spec/test_data/c_major.mid' }
  end

  it 'gives the same samples while GM time, brightness, and other controllers move' do
    ev = MB::Sound::MIDI::Event
    null_test(seconds: 0.8, sizes: [128, 200]) {
      MIDIListSource.new(
        [60, 64, 67].each_with_index.flat_map { |n, i|
          [ev.note_on(n, 0.8, time: Rational(i, 7)), ev.note_off(n, time: Rational(i, 7) + 0.2)]
        },
        [73, 75, 72, 74, 71, 1].each_with_index.flat_map { |cc, i|
          6.times.map { |k| ev.cc_raw(cc, (20 * k + 13 * i) % 128, time: Rational(k * 7 + i, 61)) }
        },
        ev.bend(0.3, time: 0.25r), ev.cc_raw(121, 0, time: 0.6r), ev.cc(99, 0, time: 1000r)
      )
    }
  end

  it 'gives the same samples for a looping clip through seeks' do
    clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3.n4, MB::Sound::B3).n8.loop

    [true, false].map { |fast|
      MB::Sound::Notes.fast_paths = fast
      src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)
      synth = MB::Sound::Synth.new(src, voices: 2, spares: 1, seed: 3, &patch)
      30.times.map { |i|
        src.seek(0.3) if i == 12
        synth.sample(400).dup
      }.reduce(:concatenate).to_a
    }.then { |fast, slow| expect(fast).to eq(slow) }
  end
end
