RSpec.describe(MB::Sound::MIDI::ClipSource) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:rate) { 48000 }

  # Plays +clip+ through a ClipSource, one +buffer+ at a time, calling
  # +tempo+ (if given) with the buffer index before each buffer so the
  # tempo can change.  Returns a trigger and a gate rebuilt from the
  # source's events by sample index, to compare with the old ClipNode
  # renderers' outputs (see spec/support/clip_node_reference.rb).
  def render(clip, buffer:, buffers:, tempo: nil)
    src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)

    src_trig = Numo::SFloat.zeros(buffer * buffers)
    src_gate = Numo::SFloat.zeros(buffer * buffers)
    active = 0
    last = 0

    buffers.times do |b|
      tempo&.call(b)
      start = b * buffer
      from = Rational(start, rate)
      src.read(from, Rational(start + buffer, rate)).each do |e|
        idx = start + ((e.time - from) * rate).floor
        src_gate[last...idx] = active > 0 ? 1 : 0 if idx > last
        last = idx
        if e.note_on?
          active += 1
          src_trig[idx] = e.velocity if e.velocity.abs > src_trig[idx].abs
        else
          active -= 1
        end
      end
    end
    src_gate[last..] = active > 0 ? 1 : 0

    [src_trig, src_gate]
  end

  it 'puts note edges on the same samples as ClipNode did' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8.t.legato(0.7).loop
    [441, 800, 1000].each do |buffer|
      ref = ClipNodeReference["source_edges_#{buffer}"]
      st, sg = render(clip, buffer: buffer, buffers: 48000 * 3 / buffer)
      expect(st.to_a).to eq(ref[:trigger]), "triggers with buffer #{buffer}"
      expect(sg.to_a).to eq(ref[:gate]), "gate with buffer #{buffer}"
      expect(st.ne(0).count_true).to be > 10
    end
  end

  it 'follows tempo changes like ClipNode did' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4.n16, MB::Sound::G4).n8.loop
    tempo = ->(b) { transport.bpm = { 20 => 97, 50 => 143.5, 90 => 61 }.fetch(b, transport.bpm) }
    ref = ClipNodeReference[:source_tempo]
    st, sg = render(clip, buffer: 800, buffers: 150, tempo: tempo)
    expect(st.to_a).to eq(ref[:trigger])
    expect(sg.to_a).to eq(ref[:gate])
  end

  it 'plays a non-looping clip to its end' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8
    _, sg = render(clip, buffer: 800, buffers: 30)
    expect(sg.to_a).to eq(ClipNodeReference[:source_end_gate])

    src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)
    expect(src.music_end).to eq(1/2r)
    src.read(0, 1/2r - 1/96000r)
    expect(src.ended?).to eq(false)
    src.read(1/2r - 1/96000r, 1/2r)
    expect(src.ended?).to eq(false) # the last note-off is at 1/2
    expect(src.read(1/2r, 1/2r + 1/96000r).map(&:type)).to eq([:note_off])
    expect(src.ended?).to eq(true)
  end

  it 'never ends a looping clip' do
    src = MB::Sound::MIDI::ClipSource.new(MB::Sound::C4.n8.loop, transport: transport)
    src.read(0, 100)
    expect(src.ended?).to eq(false)
    expect(src.music_end).to eq(nil)
  end

  it 'makes note events with the clip values, velocities, and channel' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::A4.n4, 440.hz).n8.vel(0.3)
    src = MB::Sound::MIDI::ClipSource.new(clip, channel: 5, transport: transport)
    events = src.read(0, 2)
    expect(events.map(&:type)).to eq([:note_on, :note_off, :note_on, :note_off, :note_on, :note_off])
    expect(events.map(&:time)).to eq([0, 1/4r, 1/4r, 3/4r, 3/4r, 1].map(&:to_r))
    expect(events.map(&:channel).uniq).to eq([5])
    expect(events.select(&:note_on?).map(&:velocity)).to eq([0.3, 0.3, 0.3])
    expect(events[0].note).to eq(60)
    expect(events[4].note).to be_a(MB::Sound::Pitch)
    expect(events[4].bytes).to eq(nil)
  end

  it 'sorts note-offs before note-ons at the same time' do
    src = MB::Sound::MIDI::ClipSource.new(MB::Sound::C4.n8.loop, transport: transport)
    expect(src.read(0, 1/2r).map(&:type)).to eq([:note_on, :note_off, :note_on])
  end

  describe 'timeline' do
    it 'plays looping clips in phase with the timeline' do
      src = MB::Sound::MIDI::ClipSource.new(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.loop, transport: transport)
      src.start_at(1/8r, origin: 0)
      events = src.read(0, 1/4r)
      # The C4 that would end at 0 never started, so its note-off is left out
      expect(events.map { |e| [e.time, e.type, e.note] }).to eq([[0r, :note_on, 64]])
    end

    it 'plays non-looping clips from their start at the launch point' do
      src = MB::Sound::MIDI::ClipSource.new(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8, transport: transport)
      src.read(0, 1)
      gen = src.generation
      src.start_at(3, origin: 3)
      expect(src.generation).to eq(gen + 1)
      expect(src.read(1, 2).map { |e| [e.time, e.type, e.note] }).to eq([[1r, :note_on, 60], [5/4r, :note_off, 60], [5/4r, :note_on, 64], [3/2r, :note_off, 64]])
    end
  end

  describe 'loops with notes moved before their cycle (humanize)' do
    let(:base) { MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8 }
    # Every downbeat 1/64 early (1/32 s at 120 BPM)
    let(:early) {
      v = MB::Sound::Sequence::Clip::Variation.new(name: 'early', block: ->(events, _cycle, _clip) {
        events.each_with_index.map { |e, i| i == 0 ? e.with(start: e.start - 1/64r) : e }
      })
      MB::Sound::Sequence::Clip.new(base.events, length: base.length, loop: true, variations: [v])
    }

    def ons(src, from, to)
      src.read(from, to).select(&:note_on?).map { |e| [e.time, e.note] }
    end

    it 'plays the first downbeat at the start and later ones before their bar lines' do
      src = MB::Sound::MIDI::ClipSource.new(early, transport: transport)
      # 120 BPM: a cycle (1/4 whole note) per 1/2 s, 1/64 whole note = 1/32 s
      expect(ons(src, 0, 1/4r) + ons(src, 1/4r, 1)).to eq([[0r, 60], [1/4r, 64], [1/2r - 1/32r, 60], [3/4r, 64], [1r - 1/32r, 60]])
    end

    it 'plays a downbeat moved before the position a loop is launched or seeked to, once' do
      src = MB::Sound::MIDI::ClipSource.new(early, transport: transport)
      src.start_at(1/4r, origin: 1/4r) # cycle 1's downbeat was due 1/32 s before
      expect(ons(src, 0, 1/2r)).to eq([[0r, 60], [1/4r, 64], [1/2r - 1/32r, 60]])
      expect(ons(src, 1/2r, 1)).to eq([[3/4r, 64], [1r - 1/32r, 60]])

      src.seek(1) # seconds into the clip: cycle 2's start
      expect(ons(src, 1, 3/2r)).to eq([[1r, 60], [5/4r, 64], [3/2r - 1/32r, 60]])

      # A seek into the middle of a cycle doesn't replay its downbeat
      src.seek(1/4r)
      expect(ons(src, 3/2r, 2)).to eq([[3/2r, 64], [7/4r - 1/32r, 60]])
    end

    it 'plays the downbeat of a cycle that a launch-aligned loop is launched on' do
      src = MB::Sound::MIDI::ClipSource.new(early.loop(align: :launch), transport: transport)
      src.start_at(3/8r, origin: 3/8r)
      expect(ons(src, 0, 1/2r)).to eq([[0r, 60], [1/4r, 64], [1/2r - 1/32r, 60]])
    end

    it 'plays the downbeat of the cycle a swap lands on' do
      src = MB::Sound::MIDI::ClipSource.new(base.loop, transport: transport)
      expect(ons(src, 0, 1/4r)).to eq([[0r, 60]])
      src.swap_clip(early, time: 1/4r)
      # The swap lands on cycle 2 at 1/2 s, whose downbeat was due 1/32 s earlier
      expect(ons(src, 1/4r, 1)).to eq([[1/4r, 64], [1/2r, 60], [3/4r, 64], [1r - 1/32r, 60]])
    end
  end

  describe 'launch-aligned loops' do
    let(:clip) { MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8 }
    let(:launch_loop) { clip.loop(align: :launch) }

    def notes(src, from, to)
      src.read(from, to).map { |e| [e.time, e.type, e.note] }
    end

    it 'start at their beginning when launched' do
      src = MB::Sound::MIDI::ClipSource.new(launch_loop, transport: transport)
      src.start_at(3/8r, origin: 3/8r) # timeline loops would be 1/8 into the E4
      expect(notes(src, 0, 1/2r)).to eq([[0r, :note_on, 60], [1/4r, :note_off, 60], [1/4r, :note_on, 64]])
    end

    it 'count from the exact launch time when the first sample starts before it' do
      src = MB::Sound::MIDI::ClipSource.new(launch_loop, transport: transport)
      src.start_at(3/8r - 1/1000r, origin: 3/8r - 1/1000r, launch: 3/8r)
      # 120 BPM: 1/1000 whole note is 2 ms, then every 1/8 (0.25 s)
      expect(notes(src, 0, 1/2r)).to eq([[1/500r, :note_on, 60], [63/250r, :note_off, 60], [63/250r, :note_on, 64]])
    end

    # A launch-aligned loop launched at +launch+ plays like the timeline
    # loop rotated by +launch+, wherever the timeline seeks
    it 'keep their anchor through seeks and rewinds, matching a rotated timeline loop' do
      launch = 3/8r
      src = MB::Sound::MIDI::ClipSource.new(launch_loop, transport: transport)
      ref = MB::Sound::MIDI::ClipSource.new(clip.rotate(launch).loop, transport: transport)
      [src, ref].each { |s| s.start_at(launch, origin: launch) }
      expect(notes(src, 0, 1/3r)).to eq(notes(ref, 0, 1/3r))

      [5/16r, 0r, 1/16r, 7/3r, 3/8r].each_with_index do |pos, i|
        t = 1/3r * (i + 1)
        [src, ref].each { |s| s.start_at(pos, origin: launch) }
        expect(notes(src, t, t + 1/3r)).to eq(notes(ref, t, t + 1/3r)), "seek to #{pos}"
        expect(src.chase&.event&.note).to eq(ref.chase&.event&.note)
      end
    end

    it 'start at their beginning on a swap, keeping that anchor through seeks until a new launch' do
      src = MB::Sound::MIDI::ClipSource.new(MB::Sound::D4.n4.loop, transport: transport)
      src.start_at(0)
      src.swap_clip(launch_loop, time: 3/8r)
      # The swap at 3/8 whole note (0.75 s) starts the C4
      expect(notes(src, 0, 1)).to eq([[0r, :note_on, 62], [1/2r, :note_off, 62], [1/2r, :note_on, 62], [3/4r, :note_off, 62], [3/4r, :note_on, 60]])

      # A seek in the same graph keeps the swap's anchor (3/8): 1/2 is 1/8
      # past it, in the E4 (the sounding C4 ends at the jump)
      src.start_at(1/2r, origin: 0)
      expect(notes(src, 1, 5/4r)).to eq([[1r, :note_off, 60], [1r, :note_on, 64]])

      # A new launch (e.g. #resume) starts the clip over from there
      src.start_at(5/8r, origin: 5/8r)
      expect(notes(src, 5/4r, 3/2r)).to eq([[5/4r, :note_off, 64], [5/4r, :note_on, 60]])
    end
  end

  describe '#seek and #restart' do
    let(:src) { MB::Sound::MIDI::ClipSource.new(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8, transport: transport) }

    it 'restarts the clip at the current stream time' do
      a = src.read(0, 1)
      expect(src.ended?).to eq(true)
      src.restart
      expect(src.ended?).to eq(false)
      b = src.read(1, 2)
      expect(b.map(&:note)).to eq(a.map(&:note))
      expect(b.map(&:time)).to eq(a.map { |e| e.time + 1 })
    end

    it 'seeks in seconds at the current tempo' do
      src.seek(1/4r)
      expect(src.read(0, 1/4r).map { |e| [e.time, e.type, e.note] }).to eq([[0r, :note_on, 64]])
    end
  end

  describe '#swap_clip' do
    it 'switches clips at an exact timeline position' do
      src = MB::Sound::MIDI::ClipSource.new(MB::Sound::C4.n8.loop, transport: transport)
      src.swap_clip(MB::Sound::E4.n16.loop, time: 1/4r)
      expect(src.pending_clip.events.first.value).to eq(64)
      events = src.read(0, 3/4r) # 0.75 s = 3/8 whole notes
      expect(events.map { |e| [e.time, e.type, e.note] }).to eq([
        [0r, :note_on, 60], [1/4r, :note_off, 60], [1/4r, :note_on, 60],
        # the swap at 1/4 whole note (0.5 s) releases the C4, and the E4
        # that would have ended there never started, so its note-off is left out
        [1/2r, :note_off, 60], [1/2r, :note_on, 64], [5/8r, :note_off, 64], [5/8r, :note_on, 64],
      ])
      expect(src.pending_clip).to eq(nil)
      expect(src.clip.events.first.value).to eq(64)
    end

    it 'switches at the next read without a time' do
      src = MB::Sound::MIDI::ClipSource.new(MB::Sound::C4.n8, transport: transport)
      src.read(0, 1/10r)
      src.swap_clip(MB::Sound::E4.n8)
      expect(src.read(1/10r, 1).map { |e| [e.time, e.type, e.note] }).to eq([[1/10r, :note_off, 60], [1/10r, :note_on, 64], [7/20r, :note_off, 64]])
    end
  end

  describe '#chase and #first_note' do
    let(:clip) { MB::Sound.seq(MB::Sound::C4, MB::Sound.seq(MB::Sound::E4).vel(0.5), MB::Sound::G4).n4.loop }

    it 'gives the first note' do
      src = MB::Sound::MIDI::ClipSource.new(clip, channel: 3, transport: transport)
      expect(src.first_note).to have_attributes(type: :note_on, note: 60, channel: 3)
      expect(src.chase).to eq(nil)
    end

    it 'chases the note most recently started at a timeline jump' do
      src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)
      src.read(0, 1/10r)
      src.start_at(5/16r) # in the E4 (1/4 to 1/2 whole note)
      c = src.chase
      expect(c.generation).to eq(src.generation)
      expect(c.time).to eq(1/10r)
      expect(c.event).to have_attributes(type: :note_on, note: 64, velocity: 0.5, time: 1/10r)
    end

    it 'chases at a clip swap' do
      src = MB::Sound::MIDI::ClipSource.new(MB::Sound::C4.n8.loop, transport: transport)
      src.swap_clip(clip, time: 3/8r)
      src.read(0, 1)
      expect(src.chase.time).to eq(3/4r)
      expect(src.chase.event.note).to eq(64)
      expect(src.chase.generation).to eq(src.generation)
    end
  end
end
