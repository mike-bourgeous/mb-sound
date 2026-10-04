RSpec.describe(MB::Sound::MIDI::ClipSource) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:rate) { 48000 }

  # Plays +clip+ through a ClipNode::Trigger and ClipNode::Gate and through
  # a ClipSource, one +buffer+ at a time, calling +tempo+ (if given) with the
  # buffer index before each buffer so the tempo can change.  Returns the
  # ClipNode outputs and the same signals rebuilt from the source's events
  # by sample index.
  def compare(clip, buffer:, buffers:, tempo: nil)
    trigger = MB::Sound::Sequence::ClipNode::Trigger.new(clip, range: 0.0..1.0, transport: transport)
    gate = MB::Sound::Sequence::ClipNode::Gate.new(clip, transport: transport)
    src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)

    node_trig = []
    node_gate = []
    src_trig = Numo::SFloat.zeros(buffer * buffers)
    src_gate = Numo::SFloat.zeros(buffer * buffers)
    active = 0
    last = 0

    buffers.times do |b|
      tempo&.call(b)
      node_trig << trigger.sample(buffer).dup
      node_gate << gate.sample(buffer).dup

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

    [node_trig.reduce(:concatenate), node_gate.reduce(:concatenate), src_trig, src_gate]
  end

  it 'puts note edges on the same samples as ClipNode' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8.t.legato(0.7).loop
    [441, 800, 1000].each do |buffer|
      nt, ng, st, sg = compare(clip, buffer: buffer, buffers: 48000 * 3 / buffer)
      expect(st.to_a).to eq(nt.to_a), "triggers with buffer #{buffer}"
      expect(sg.to_a).to eq(ng.to_a), "gate with buffer #{buffer}"
      expect(nt.ne(0).count_true).to be > 10
    end
  end

  it 'follows tempo changes like ClipNode' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4.n16, MB::Sound::G4).n8.loop
    tempo = ->(b) { transport.bpm = { 20 => 97, 50 => 143.5, 90 => 61 }.fetch(b, transport.bpm) }
    nt, ng, st, sg = compare(clip, buffer: 800, buffers: 150, tempo: tempo)
    expect(st.to_a).to eq(nt.to_a)
    expect(sg.to_a).to eq(ng.to_a)
  end

  it 'plays a non-looping clip to its end' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8
    _, ng, _, sg = compare(clip, buffer: 800, buffers: 30) # ClipNodes end at 24000 samples
    expect(sg.to_a).to eq(ng.to_a)

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
