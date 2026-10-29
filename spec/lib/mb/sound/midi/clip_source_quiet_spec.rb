# Quiet reads (int-frames-1): ClipSource reads that no edge can land in
# compare integer frames against the precomputed frame of the next possible
# edge instead of reading the clip with Rational positions.  Each example
# plays the same script of reads (random buffer sizes and sample rates,
# tempo changes, seeks, swaps) with quiet reads on and off and expects the
# same events, clip positions, and ends.
RSpec.describe(MB::Sound::MIDI::ClipSource, 'quiet reads') do
  after { MB::Sound::MIDI::ClipSource.quiet_reads = true }

  let(:c4) { MB::Sound::C4 }
  let(:e4) { MB::Sound::E4 }
  let(:g4) { MB::Sound::G4 }

  # Plays +clip+ through a ClipSource for +reads+ reads from stream time
  # +t0+ (seconds) after starting it at timeline position +start+ (whole
  # notes), with quiet reads on or off.  Returns what each read gave, the
  # clip position after it, and whether the source had ended, plus how
  # many reads were quiet.
  def script(clip, quiet:, seed: 1, reads: 400, t0: 0r, start: nil, bpm: 120, rates: [48000], counts: [1, 7, 128, 367, 368, 800],
             tempos: [], seek: 0, swaps: [], off_grid: 0)
    MB::Sound::MIDI::ClipSource.quiet_reads = quiet
    rng = Random.new(seed)
    transport = MB::Sound::Sequence::Transport.new(bpm: bpm)
    src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)
    src.start_at(start) if start
    t = t0
    quiet_reads = 0
    log = Array.new(reads) do |i|
      transport.bpm = tempos.sample(random: rng) if !tempos.empty? && rng.rand < 0.05
      src.start_at(rng.rand(0..64) * 1/16r + (start || 0)) if seek > 0 && rng.rand < seek
      if !swaps.empty? && rng.rand < 0.03
        # (at the next read, or later in it)
        at = rng.rand < 0.5 ? nil : src.clip_position + rng.rand(0..8) * 1/32r
        src.swap_clip(swaps.sample(random: rng), time: at)
      end

      rate = rates.sample(random: rng)
      to = t + Rational(counts.sample(random: rng), rate)
      to += Rational(1, rng.rand(2..97) * 1000) if rng.rand < off_grid
      events = src.read(t, to)
      quiet_reads += 1 if src.instance_variable_get(:@lazy_from)
      t = to
      [i, events.map(&:inspect), src.clip_position, src.ended?]
    end
    [log, quiet_reads]
  end

  # Expects the same script with quiet reads on and off, and that most
  # reads were quiet.
  def expect_same(clip, min_quiet: 0.5, **opts)
    full, none = script(clip, quiet: false, **opts)
    quiet, count = script(clip, quiet: true, **opts)
    expect(none).to eq(0)
    full.zip(quiet).each do |f, q|
      expect(q).to eq(f), "read #{f[0]}: quiet #{q.inspect}, full #{f.inspect}"
    end
    expect(full.sum { |_i, ev, _p, _e| ev.length }).to be > 0
    expect(count).to be >= (min_quiet * full.length).floor
  end

  it 'gives the same events and positions for a plain loop' do
    expect_same(MB::Sound.seq(c4, e4, g4).n8.legato(0.7).loop, seed: 3)
  end

  it 'gives the same events across tempo changes' do
    expect_same(MB::Sound.seq(c4, e4.n16, g4).n8.loop, seed: 5, tempos: [61, 97, 120, 138.75, 143.5, 172])
  end

  it 'gives the same events at other sample rates, off their grids, and mixed' do
    clip = MB::Sound.seq(c4, e4, g4, c4.up).n16.loop
    expect_same(clip, seed: 7, rates: [44100])
    expect_same(clip, seed: 8, rates: [96000, 48000], min_quiet: 0.3)
    expect_same(clip, seed: 9, off_grid: 0.2, min_quiet: 0.3)
  end

  it 'gives the same events hours into the timeline and the stream' do
    clip = MB::Sound.seq(c4, e4, g4).n8.t.loop
    hours = 3 * 3600 * 138.75r / 240 # whole notes in 3 hours at 138.75 BPM
    expect_same(clip, seed: 11, bpm: 138.75, start: hours.floor + 1/3r)
    # (the first read crosses the hours before the stream time)
    expect_same(MB::Sound.seq(c4, e4).n2.loop, seed: 12, bpm: 138.75, t0: Rational(3600 * 48000 + 17, 48000), tempos: [138.75, 87], min_quiet: 0.8)
  end

  it 'gives the same events through seeks and swaps' do
    a = MB::Sound.seq(c4, e4, g4).n8.loop
    b = MB::Sound.seq(g4.n4, e4.n16, c4.n16).loop
    c = MB::Sound.seq(c4, g4).n8.loop(align: :launch)
    expect_same(a, seed: 13, seek: 0.02, swaps: [a, b, c], min_quiet: 0.3)
  end

  it 'gives the same events for swing, humanized (varying), chance, and long notes' do
    base = MB::Sound.seq(c4, e4, g4, e4).n8
    expect_same(base.swing(0.62).loop, seed: 15)
    expect_same(base.loop.humanize(1/32r, vary: true, seed: 4), seed: 16)
    expect_same(base.loop.chance(0.5), seed: 17)
    expect_same(MB::Sound.seq(c4.n2.d, e4.n1).loop, seed: 18) # notes longer than the loop's step
  end

  it 'gives the same events for clips with controller lanes (steps and curves) through seeks and swaps' do
    lanes = { cc1: [[0r, 0.1], [3r/16, 0.6], [5r/8, 0.9]], cc74: { curve: :cubic, points: [[1r/8, 0.2], [1r/2, 0.8], [7r/8, 0.3]], resolution: 1r/64 } }
    a = MB::Sound.events([0r, 1r/8, 60, 0.8], [1r/2, 1r/8, 64, 0.8], length: 1r, loop: true, controls: lanes)
    b = MB::Sound.events([1r/4, 1r/8, 67, 0.8], length: 1r/2, loop: true, controls: { bend: { points: [[0r, -0.5], [1r/4, 0.5]], range: 12 } })
    expect_same(a, seed: 21, min_quiet: 0.3)
    expect_same(a, seed: 22, seek: 0.02, swaps: [a, b], min_quiet: 0.2, tempos: [97, 120, 172])
    expect_same(MB::Sound.events(length: 1r, controls: lanes), seed: 23, min_quiet: 0.3) # (controllers only)
  end

  it 'gives the same events for a one-shot clip to its end' do
    expect_same(MB::Sound.seq(c4, e4, g4).n4, seed: 19, reads: 120, min_quiet: 0.2)
  end

  # Read ends (frames at 48 kHz) one frame before, on, and one and two
  # frames after every edge and loop cycle start of +clip+ in its first
  # +seconds+ at +bpm+ (edges from a full read), so quiet reads end exactly
  # where an edge or a cycle comes into reach.
  def boundaries(clip, bpm:, seconds:)
    MB::Sound::MIDI::ClipSource.quiet_reads = false
    src = MB::Sound::MIDI::ClipSource.new(clip, transport: MB::Sound::Sequence::Transport.new(bpm: bpm))
    times = src.read(0r, Rational(seconds)).map(&:time)
    wnps = bpm.to_r / 240
    times += (0..(seconds * wnps / clip.length).ceil).map { |k| k * clip.length / wnps } if clip.looping?
    times.flat_map { |t|
      f = (t * 48000).floor
      c = (t * 48000).ceil
      [f - 1, f, f + 1, f + 2, c - 1, c, c + 1]
    }.select(&:positive?).uniq.sort
  end

  # Like #script, reading up to each frame of +ends+ in turn.
  def boundary_script(clip, ends, quiet:, bpm:)
    MB::Sound::MIDI::ClipSource.quiet_reads = quiet
    src = MB::Sound::MIDI::ClipSource.new(clip, transport: MB::Sound::Sequence::Transport.new(bpm: bpm))
    t = 0r
    ends.map do |f|
      to = Rational(f, 48000)
      events = src.read(t, to)
      t = to
      [f, events.map(&:inspect), src.clip_position]
    end
  end

  it 'gives the same events for reads ending right at edges and cycle starts' do
    [120, 138.75, 97.3].each do |bpm|
      [
        MB::Sound.seq(c4, e4, g4).n8.t.legato(0.6).loop,
        MB::Sound.seq(c4, e4.n16, g4).n8.swing(0.6).loop,
        MB::Sound.seq(c4, e4).n8.loop.humanize(1/64r, vary: true, seed: 5),
        MB::Sound.seq(c4, e4, g4).n16,
      ].each do |clip|
        ends = boundaries(clip, bpm: bpm, seconds: 3)
        full = boundary_script(clip, ends, quiet: false, bpm: bpm)
        quiet = boundary_script(clip, ends, quiet: true, bpm: bpm)
        full.zip(quiet).each { |f, q| expect(q).to eq(f), "#{bpm} BPM #{clip}: read to frame #{f[0]}" }
      end
    end
  end

  it 'never reads a loop cycle earlier than the full read did' do
    # Variations (here generated per cycle) make a cycle's events when
    # #edges first reads it, so quiet reads may not look ahead
    made = { false => [], true => [] }
    ends = boundaries(MB::Sound.seq(c4, e4).n8.loop.humanize(1/64r, vary: true, seed: 2), bpm: 120, seconds: 2)
    [false, true].each do |quiet|
      clip = MB::Sound.seq(c4, e4).n8.loop.humanize(1/64r, vary: true, seed: 2)
      clip.singleton_class.prepend(Module.new do
        define_method(:events_for) do |cycle|
          made[quiet] << cycle unless made[quiet].include?(cycle)
          super(cycle)
        end
      end)
      MB::Sound::MIDI::ClipSource.quiet_reads = quiet
      src = MB::Sound::MIDI::ClipSource.new(clip, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      t = 0r
      reads = []
      ends.each do |f|
        n = made[quiet].length
        src.read(t, t = Rational(f, 48000))
        reads << f if made[quiet].length > n
      end
      made[quiet] = [made[quiet], reads]
    end
    expect(made[true]).to eq(made[false])
    expect(made[false][0].length).to be > 4
  end
end
