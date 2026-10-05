RSpec.describe(MB::Sound::MIDI::Allocator) do
  let(:ev) { MB::Sound::MIDI::Event }

  # Events spaced 10 ms apart in the order given (Arrays share one time).
  def timeline(*events)
    events.each_with_index.flat_map { |e, idx| Array(e).map { |x| x.at(Rational(idx, 100)) } }
  end

  def stream(*events)
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(timeline(*events)))
  end

  # Glide events are left out unless asked for (see 'glide modes').
  def alloc(*events, **opts)
    MB::Sound::MIDI::Allocator.new(stream(*events), glide_mode: nil, **opts)
  end

  # Each lane's events as compact strings ("on60@2" = note-on 60 at 20 ms),
  # reading every lane in +step+ second reads up to +seconds+.
  def lanes(a, seconds: 1, step: nil)
    readers = a.lanes.map(&:reader)
    out = Array.new(readers.length) { [] }
    step ||= seconds
    (seconds / step).ceil.times do
      readers.each_with_index { |r, idx| out[idx].concat(r.next(step)) }
    end
    out.map { |l| l.map { |e| short(e) } }
  end

  def short(e)
    t = (e.time * 100).round
    case e.type
    when :note_on then "#{e.legato ? 'leg' : 'on'}#{e.note}@#{t}"
    when :note_off then "off#{e.note}@#{t}"
    when :choke then "choke#{e.note}@#{t}"
    when :glide then "glide#{e.note}@#{t}"
    when :cc then "cc#{e.note}@#{t}"
    else "#{e.type}@#{t}"
    end
  end

  # Checks that a lane's events never start a note while another key
  # sounds, only end sounding notes, and end every note.
  def expect_one_note_at_a_time(log)
    sounding = Hash.new(0)
    log.each do |e|
      key = [e.channel, e.note]
      case e.type
      when :note_on
        expect(sounding.keys - [key]).to eq([])
        sounding[key] += 1
      when :note_off
        expect(sounding[key]).to be > 0
        sounding[key] -= 1
        sounding.delete(key) if sounding[key] == 0
      when :choke
        # Released (ringing) lanes are choked too
        expect(sounding.keys - [key]).to eq([])
        sounding.clear
      end
    end
    expect(sounding).to be_empty
  end

  def on(n, v = 1.0, ch: 0)
    ev.note_on(n, v, channel: ch)
  end

  def off(n, ch: 0)
    ev.note_off(n, channel: ch)
  end

  describe '#initialize' do
    it 'makes voices + spares lanes that are Streams' do
      a = alloc(voices: 3, spares: 2)
      expect(a.lanes.length).to eq(5)
      expect(a.lanes).to all(be_a(MB::Sound::MIDI::Stream))
      expect(a.lanes.map(&:index)).to eq([0, 1, 2, 3, 4])
      expect(a.lanes.map(&:state)).to all(eq(:free))
      expect(MB::Sound::MIDI::Stream.for(a.lanes[1])).to equal(a.lanes[1])
    end

    it 'accepts anything Stream.for accepts' do
      a = MB::Sound::MIDI::Allocator.new('spec/test_data/c_major.mid', voices: 2, spares: 0)
      expect(a.lanes[0].reader.next(1).count(&:note_on?)).to be > 0
    end

    it 'rejects bad arguments' do
      expect { alloc(voices: 0) }.to raise_error(ArgumentError, /Voices/)
      expect { alloc(spares: -1) }.to raise_error(ArgumentError, /Spares/)
      expect { alloc(steal: :loudest) }.to raise_error(ArgumentError, /loudest/)
      expect { alloc(protect: :middle) }.to raise_error(ArgumentError, /middle/)
    end

    it 'shows up in graph traversal' do
      s = stream(on(60))
      a = MB::Sound::MIDI::Allocator.new(s)
      expect(a.lanes[0].graph).to include(a, s)
      expect(a.lanes[0].to_s).to eq('MIDI lane 0')
    end
  end

  describe 'note assignment' do
    it 'gives each note its own free lane while voices are free' do
      a = alloc(on(60), on(64), on(67), off(64), off(60), off(67), voices: 4, spares: 0)
      expect(lanes(a)).to eq([
        ['on60@0', 'off60@4'],
        ['on64@1', 'off64@3'],
        ['on67@2', 'off67@5'],
        [],
      ])
      expect(a.lanes.map(&:state)).to eq([:released, :released, :released, :free])
    end

    it 'routes note-offs by channel and note' do
      a = alloc(on(60, ch: 0), on(60, ch: 1), off(60, ch: 1), off(60, ch: 0), voices: 2, spares: 0)
      expect(lanes(a)).to eq([['on60@0', 'off60@3'], ['on60@1', 'off60@2']])
      expect(a.lanes.map(&:channel)).to eq([0, 1])
    end

    it 'counts overlapping notes on the same key, ending the oldest first' do
      a = alloc(on(60), on(60), off(60), off(60), voices: 4, spares: 0)
      expect(lanes(a)).to eq([['on60@0', 'off60@2'], ['on60@1', 'off60@3'], [], []])
    end

    it 'keeps a lane sounding until each note retriggered on it ends' do
      a = alloc(on(60), on(60), off(60), voices: 1, spares: 1, mono: false)
      expect(lanes(a)).to eq([['on60@0', 'on60@1', 'off60@2'], []])
      expect(a.lanes[0].state).to eq(:sounding)
    end

    it 'keeps event times exact and lanes on the input time base' do
      s = MB::Sound::MIDI::Stream.new(MIDIListSource.new(on(60).at(1/3r), off(60).at(2/3r)))
      a = MB::Sound::MIDI::Allocator.new(s, voices: 1, spares: 0)
      r = a.lanes[0].reader
      expect(r.next(1/2r).map(&:time)).to eq([1/3r])
      expect(r.next(1/2r).map(&:time)).to eq([2/3r])
    end

    it 'gives each lane the same events however the lanes read' do
      events = [on(60), on(62), on(64), off(62), on(65), on(67), off(60), off(64), on(69), off(65), off(67), off(69)]
      whole = lanes(alloc(*events, voices: 3), seconds: 1)
      stepped = lanes(alloc(*events, voices: 3), seconds: 1, step: 3/100r)

      reversed = alloc(*events, voices: 3)
      backwards = reversed.lanes.reverse.map { |l| l.reader.next(1).map { |e| short(e) } }.reverse

      expect(stepped).to eq(whole)
      expect(backwards).to eq(whole)
    end

    it 'gives the same allocation every time (deterministic)' do
      events = 40.times.map { |i| i.even? ? on(40 + (i * 7) % 30) : off(40 + ((i - 1) * 7) % 30) }
      expect(lanes(alloc(*events, voices: 3))).to eq(lanes(alloc(*events, voices: 3)))
    end

    it 'reuses the lane free the longest' do
      a = alloc(on(60), off(60), on(62), off(62), on(64), voices: 2, spares: 1)
      a.lanes.each { |l| l.idle_check = -> { true } }
      out = lanes(a, step: 1/100r)
      expect(out.map(&:first)).to eq(['on60@0', 'on62@2', 'on64@4'])
    end
  end

  describe 'stealing' do
    it 'chokes the oldest released lane and plays the new note on a spare' do
      a = alloc(on(60), on(62), off(60), on(64), voices: 2, spares: 1)
      expect(lanes(a)).to eq([
        ['on60@0', 'off60@2', 'choke60@3'],
        ['on62@1'],
        ['on64@3'],
      ])
      expect(a.lanes.map(&:state)).to eq([:choking, :sounding, :sounding])
    end

    it 'chokes the oldest sounding lane when none are released, dropping its note-off' do
      a = alloc(on(60), on(62), on(64), off(60), off(64), voices: 2, spares: 1)
      expect(lanes(a)).to eq([
        ['on60@0', 'choke60@2'],
        ['on62@1'],
        ['on64@2', 'off64@4'],
      ])
    end

    it 'retriggers the lane playing the same note with :same_note' do
      a = alloc(on(60), on(62), off(60), on(60), off(60), voices: 2, spares: 1)
      expect(lanes(a)).to eq([['on60@0', 'off60@2', 'on60@3', 'off60@4'], ['on62@1'], []])
    end

    it 'retriggers a sounding lane on the same note, counting both notes' do
      a = alloc(on(60), on(62), on(60), off(60), off(60), voices: 2, spares: 1)
      expect(lanes(a)).to eq([['on60@0', 'on60@2', 'off60@3', 'off60@4'], ['on62@1'], []])
      expect(a.lanes[0].state).to eq(:released)
    end

    it 'follows the steal chain in order' do
      events = [on(60), on(62), off(62), on(60)]
      expect(lanes(alloc(*events, voices: 2, spares: 1, steal: [:oldest_released, :same_note]))).to eq([
        ['on60@0'], ['on62@1', 'off62@2', 'choke62@3'], ['on60@3'],
      ])
      expect(lanes(alloc(*events, voices: 2, spares: 1, steal: :oldest))).to eq([
        ['on60@0', 'choke60@3'], ['on62@1', 'off62@2'], ['on60@3'],
      ])
    end

    it 'falls back to the oldest lane when no policy finds one' do
      a = alloc(on(60), on(62), on(64), voices: 2, spares: 1, steal: :oldest_released)
      expect(lanes(a)).to eq([['on60@0', 'choke60@2'], ['on62@1'], ['on64@2']])
    end

    it 'steals the lowest velocity or released lane with :quietest' do
      a = alloc(on(60, 0.9), on(62, 0.2), on(64, 0.5), on(65), voices: 3, spares: 1, steal: :quietest)
      expect(lanes(a)[1]).to eq(['on62@1', 'choke62@3'])

      b = alloc(on(60, 0.9), on(62, 0.2), off(60), on(65), voices: 2, spares: 1, steal: :quietest)
      expect(lanes(b)[0]).to eq(['on60@0', 'off60@2', 'choke60@3'])
    end

    it 'uses level checks for :quietest when given' do
      a = alloc(on(60), on(62), on(64), voices: 2, spares: 1, steal: :quietest)
      a.lanes[0].level_check = -> { 0.5 }
      a.lanes[1].level_check = -> { 0.1 }
      expect(lanes(a)[1]).to eq(['on62@1', 'choke62@2'])
    end

    it 'protects the lowest or highest sounding note' do
      events = [on(40), on(70), on(60), on(65)]
      expect(lanes(alloc(*events, voices: 3, spares: 1, steal: :oldest, protect: :lowest))[1]).to eq(['on70@1', 'choke70@3'])
      expect(lanes(alloc(*events, voices: 3, spares: 1, steal: :oldest, protect: [:lowest, :highest]))[2]).to eq(['on60@2', 'choke60@3'])
    end

    it 'counts released lanes as active until reused when there is no idle check' do
      a = alloc(on(60), off(60), on(62), off(62), on(64), voices: 2, spares: 1)
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'choke60@4'], ['on62@2', 'off62@3'], ['on64@4']])
    end

    it 'frees choking lanes after the choke time' do
      # 62 chokes 60 (lane 0) at 10 ms; the next note-on (30 ms) frees it if the choke is over
      events = [on(60), on(62), off(62), on(64)]
      short_choke = alloc(*events, voices: 1, spares: 2, mono: false, choke_time: 0.02)
      long_choke = alloc(*events, voices: 1, spares: 2, mono: false, choke_time: 0.021)
      expect(lanes(short_choke)).to eq(lanes(long_choke))
      expect(short_choke.lanes[0].state).to eq(:free)
      expect(long_choke.lanes[0].state).to eq(:choking)
      expect(short_choke.lanes.map(&:state)).to eq([:free, :choking, :sounding])
    end

    it 'takes its default choke time from Envelope' do
      expect(alloc.choke_time).to eq(3/1000r)
      expect(MB::Sound::Envelope::CHOKE_TIME).to eq(0.003)
    end

    it 'reuses the oldest choking lane when every spare is still choking' do
      a = alloc(on(60), on(62), on(64), on(65), voices: 2, spares: 1, choke_time: 1)
      expect(lanes(a)).to eq([['on60@0', 'choke60@2', 'on65@3'], ['on62@1', 'choke62@3'], ['on64@2']])
    end

    it 'hands a note straight to the victim without spares' do
      a = alloc(on(60), on(62), on(64), off(60), off(64), voices: 2, spares: 0)
      expect(lanes(a)).to eq([['on60@0', 'off60@2', 'on64@2', 'off64@4'], ['on62@1']])
    end
  end

  describe 'same-note retrigger modes' do
    # note_velocity.mid style: the same key struck three times, released in
    # between, with +vels+; released lanes stay active (no idle checks).
    def strikes(*vels)
      vels.each_with_index.flat_map { |v, idx| [on(60, v), off(60)] }
    end

    it 'defaults to :reuse and rejects unknown modes' do
      expect(alloc.retrigger).to eq(:reuse)
      expect { alloc(retrigger: :add) }.to raise_error(ArgumentError, /retrigger/)
    end

    it 'restarts the lane playing the note with :reuse, at any velocity' do
      [[1, 0.5, 0.2], [0.2, 0.5, 1]].each do |vels|
        a = alloc(*strikes(*vels), voices: 2, spares: 1, retrigger: :reuse)
        expect(lanes(a)).to eq([['on60@0', 'off60@1'], ['on60@2', 'off60@3', 'on60@4', 'off60@5'], []])
      end
    end

    it 'plays the note on a free lane with :new_voice, choking another victim' do
      [[1, 0.5, 0.2], [0.2, 0.5, 1]].each do |vels|
        a = alloc(*strikes(*vels), voices: 2, spares: 1, retrigger: :new_voice)
        expect(lanes(a)).to eq([['on60@0', 'off60@1', 'choke60@4'], ['on60@2', 'off60@3'], ['on60@4', 'off60@5']])
      end
    end

    it 'keeps the lane playing the note ringing with :new_voice when another can be stolen' do
      a = alloc(on(62), off(62), on(60), off(60), on(60, 0.5), off(60), voices: 2, spares: 1, retrigger: :new_voice)
      expect(lanes(a)).to eq([['on62@0', 'off62@1', 'choke62@4'], ['on60@2', 'off60@3'], ['on60@4', 'off60@5']])

      # :reuse restarts lane 1 instead
      b = alloc(on(62), off(62), on(60), off(60), on(60, 0.5), off(60), voices: 2, spares: 1)
      expect(lanes(b)).to eq([['on62@0', 'off62@1'], ['on60@2', 'off60@3', 'on60@4', 'off60@5'], []])
    end

    it 'falls back to restarting the lane with :new_voice and :louder when no lane is free' do
      [:new_voice, :louder].each do |mode|
        a = alloc(*strikes(1, 0.5, 0.2), voices: 2, spares: 0, retrigger: mode)
        expect(lanes(a)).to eq([['on60@0', 'off60@1'], ['on60@2', 'off60@3', 'on60@4', 'off60@5']])
      end
    end

    it 'with :louder, restarts the lane for a note at least as loud by velocity' do
      a = alloc(*strikes(0.2, 0.5, 0.5), voices: 2, spares: 1, retrigger: :louder)
      expect(lanes(a)).to eq([['on60@0', 'off60@1'], ['on60@2', 'off60@3', 'on60@4', 'off60@5'], []])
    end

    it 'with :louder, plays a softer note on a free lane' do
      a = alloc(*strikes(1, 0.5, 0.2), voices: 2, spares: 1, retrigger: :louder)
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'choke60@4'], ['on60@2', 'off60@3'], ['on60@4', 'off60@5']])
    end

    it 'with :louder, uses level checks of lanes that have read their notes' do
      make = -> {
        alloc(*strikes(1, 0.5, 0.2), voices: 2, spares: 1, retrigger: :louder).tap { |a|
          a.lanes.each { |l| l.level_check = -> { 0.1 } }
        }
      }
      # Read in 10 ms steps: lane 1 has read its notes, and its level (0.1) is below 0.2
      expect(lanes(make.(), step: 1/100r)).to eq([['on60@0', 'off60@1'], ['on60@2', 'off60@3', 'on60@4', 'off60@5'], []])
      # Read at once: lane 1 hasn't, so velocities are compared (0.2 < 0.5)
      expect(lanes(make.())).to eq([['on60@0', 'off60@1', 'choke60@4'], ['on60@2', 'off60@3'], ['on60@4', 'off60@5']])
    end

    it 'with :louder, asks the louder check with the new velocity' do
      asked = []
      a = alloc(*strikes(1, 0.5, 0.2), voices: 2, spares: 1, retrigger: :louder)
      a.lanes.each { |l|
        l.level_check = -> { 1 }
        l.louder_check = ->(vel) { asked << [l.index, vel]; true }
      }
      expect(lanes(a, step: 1/100r)[1]).to eq(['on60@2', 'off60@3', 'on60@4', 'off60@5'])
      expect(asked).to eq([[1, 0.2]])
    end

    it 'with :quietest, restarts the quietest lane playing the note' do
      events = [on(60, 1), off(60), on(60, 0.3), off(60), on(60, 0.6), off(60)]
      a = alloc(*events, voices: 2, spares: 1, retrigger: :quietest)
      expect(lanes(a)).to eq([['on60@0', 'off60@1'], ['on60@2', 'off60@3', 'on60@4', 'off60@5'], []])

      # By level checks when given (lane 0 is quieter now)
      b = alloc(*events, voices: 2, spares: 1, retrigger: :quietest)
      b.lanes[0].level_check = -> { 0.1 }
      b.lanes[1].level_check = -> { 0.2 }
      expect(lanes(b)).to eq([['on60@0', 'off60@1', 'on60@4', 'off60@5'], ['on60@2', 'off60@3'], []])

      # :reuse takes the newest
      expect(lanes(alloc(*events, voices: 2, spares: 1))[1]).to eq(['on60@2', 'off60@3', 'on60@4', 'off60@5'])
    end

    it 'acts like :reuse without :same_note in the steal chain' do
      events = strikes(1, 0.5, 0.2)
      expected = lanes(alloc(*events, voices: 2, spares: 1, steal: [:oldest]))
      [:louder, :new_voice].each do |mode|
        expect(lanes(alloc(*events, voices: 2, spares: 1, steal: [:oldest], retrigger: mode))).to eq(expected)
      end
    end

    it 'leaves notes with a free voice and mono mode alone' do
      events = strikes(1, 0.5, 0.2)
      [:reuse, :louder, :new_voice].each do |mode|
        expect(lanes(alloc(*events, voices: 3, spares: 1, retrigger: mode))).to eq(lanes(alloc(*events, voices: 3, spares: 1)))
        expect(lanes(alloc(*events, voices: 1, retrigger: mode))).to eq(lanes(alloc(*events, voices: 1)))
      end
    end

    it 'gives the same allocation every time (deterministic)' do
      events = [on(60), on(62), off(60), on(60, 0.3), off(62), on(62, 0.9), off(60), on(60, 0.1), off(60), off(62)]
      [:reuse, :louder, :new_voice, :quietest].each do |mode|
        runs = Array.new(3) { lanes(alloc(*events, voices: 2, spares: 2, retrigger: mode), step: 1/200r) }
        expect(runs.uniq.length).to eq(1)
        a = alloc(*events, voices: 2, spares: 2, retrigger: mode)
        a.lanes.each { |l| expect_one_note_at_a_time(l.reader.next(1)) }
      end
    end
  end

  describe '#spares=' do
    it 'stops new notes from going to lanes beyond voices + spares' do
      a = alloc(on(60), on(62), on(64), on(65), voices: 2, spares: 2, choke_time: 1)
      a.spares = 1
      expect(lanes(a)).to eq([['on60@0', 'choke60@2', 'on65@3'], ['on62@1', 'choke62@3'], ['on64@2'], []])
    end

    it 'accepts 0 up to the spares given to the constructor' do
      a = alloc(spares: 2)
      a.spares = 0
      expect(a.spares).to eq(0)
      expect { a.spares = 3 }.to raise_error(ArgumentError, /0 to 2/)
    end
  end

  describe 'idle checks' do
    it 'frees released lanes whose check says they are idle' do
      a = alloc(on(60), off(60), on(62), off(62), on(64), voices: 2, spares: 1)
      a.lanes.each { |l| l.idle_check = -> { true } }
      expect(lanes(a, step: 1/100r)).to eq([['on60@0', 'off60@1'], ['on62@2', 'off62@3'], ['on64@4']])
      expect(a.lanes.map(&:state)).to eq([:free, :free, :sounding])
    end

    it 'keeps released lanes whose check says they are ringing' do
      a = alloc(on(60), off(60), on(62), off(62), on(64), voices: 2, spares: 1)
      a.lanes.each { |l| l.idle_check = -> { false } }
      expect(lanes(a, step: 1/100r)).to eq([['on60@0', 'off60@1', 'choke60@4'], ['on62@2', 'off62@3'], ['on64@4']])
    end

    it 'only asks lanes that have read every note event sent to them' do
      a = alloc(on(60), off(60), on(62), off(62), on(64), voices: 2, spares: 1)
      checked = []
      a.lanes.each { |l| l.idle_check = -> { checked << l.index; true } }
      # One read: no lane has read its note-off when 64 arrives
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'choke60@4'], ['on62@2', 'off62@3'], ['on64@4']])
      expect(checked).to be_empty
    end

    it 'frees choking lanes early when idle' do
      a = alloc(on(60), on(62), on(64), [off(62), off(64)], on(65), voices: 2, spares: 1, choke_time: 1)
      a.lanes[0].idle_check = -> { true }
      out = lanes(a, step: 1/100r)
      expect(out[0]).to eq(['on60@0', 'choke60@2', 'on65@4'])
    end

    it 'reports the check result' do
      a = alloc
      expect(a.lanes[0].idle?).to eq(nil)
      a.lanes[0].idle_check = -> { 1 }
      expect(a.lanes[0].idle?).to eq(true)
    end
  end

  describe 'channel-wide events' do
    it 'sends CCs, bend, pressure, program, and system events to every lane' do
      a = alloc(on(60), ev.cc(1, 0.5), ev.bend(0.25), ev.channel_pressure(0.5), ev.program(3), ev.parse([0xf8]), voices: 1, spares: 1, mono: false)
      out = lanes(a)
      expect(out[0]).to eq(['on60@0', 'cc1@1', 'bend@2', 'channel_pressure@3', 'program@4', 'system@5'])
      expect(out[1]).to eq(out[0].drop(1))
    end

    it 'keeps the stream pitch bend range on bends' do
      a = MB::Sound::MIDI::Allocator.new(stream(ev.bend(1)).bend_range(12), voices: 1, spares: 0)
      expect(a.lanes[0].reader.next(1).first.bend_semitones).to eq(12)
    end

    it 'sends poly pressure only to lanes holding its key' do
      a = alloc(on(60), on(62), ev.poly_pressure(62, 0.5), voices: 2, spares: 0)
      expect(lanes(a)).to eq([['on60@0'], ['on62@1', 'poly_pressure@2']])
    end

    it 'releases every lane on the channel at all notes off (123), ignoring later note-offs' do
      a = alloc(on(60), on(62), on(64, ch: 1), ev.cc(123, 0), on(60), off(60), off(62), off(60), voices: 4, spares: 0)
      expect(lanes(a)).to eq([
        ['on60@0', 'off60@3', 'cc123@3'],
        ['on62@1', 'off62@3', 'cc123@3'],
        ['on64@2', 'cc123@3'],
        ['cc123@3', 'on60@4', 'off60@5'],
      ])
      expect(a.lanes[2].state).to eq(:sounding)
    end

    it 'chokes every lane on the channel at all sound off (120)' do
      a = alloc(on(60), on(62), off(62), ev.cc(120, 0), off(60), voices: 2, spares: 0)
      expect(lanes(a)).to eq([['on60@0', 'choke60@3', 'cc120@3'], ['on62@1', 'off62@2', 'choke62@3', 'cc120@3']])
      expect(a.lanes.map(&:state)).to eq([:choking, :choking])
    end

    it 'passes reset controllers (121) through' do
      a = alloc(on(60), ev.cc(121, 0), voices: 1, spares: 0)
      expect(lanes(a)).to eq([['on60@0', 'cc121@1']])
      expect(a.lanes[0].state).to eq(:sounding)
    end
  end

  describe 'jumps' do
    it 'releases lanes with the note-offs the source sends at a seek' do
      s = stream(on(60), on(64), off(60), off(64))
      a = MB::Sound::MIDI::Allocator.new(s, voices: 2, spares: 0, glide_mode: nil)
      readers = a.lanes.map(&:reader)
      readers.each { |r| r.next(2/100r) }
      gen = readers[0].generation
      a.lanes[1].seek(0)
      out = readers.map { |r| r.next(3/100r).map { |e| short(e) } }
      expect(out).to eq([['off60@2', 'on60@2', 'off60@4'], ['off64@2', 'on64@3']])
      expect(readers[0].generation).to eq(gen + 1)
    end

    it 'keeps lanes balanced across seeks of a MIDI file with a sustain transform' do
      s = MB::Sound::MIDI::Stream.for('spec/test_data/c_major.mid').sustain
      a = MB::Sound::MIDI::Allocator.new(s, voices: 2)
      readers = a.lanes.map(&:reader)
      logs = Array.new(readers.length) { [] }
      read = ->(seconds) { (seconds * 100).round.times { readers.each_with_index { |r, idx| logs[idx].concat(r.next(1/100r)) } } }

      read.(0.4) # seeks while 28 is held
      s.seek(0.6)
      read.(0.5)
      s.restart
      read.(30)

      expect(logs.flatten.count(&:note_on?)).to be > 10
      logs.each do |log| expect_one_note_at_a_time(log) end
      expect(logs.flatten.count(&:choke?)).to be > 0
      expect(readers.map(&:ended?)).to all(eq(true))
    end

    it 'ends lanes when the input has ended and been read' do
      a = alloc(on(60), off(60), voices: 1, spares: 1, mono: false)
      r = a.lanes.map(&:reader)
      r.each { |x| x.next(1) }
      expect(r.map(&:ended?)).to eq([true, true])
      expect(a.ended?).to eq(true)
    end
  end

  describe 'mono mode' do
    it 'is the default for one voice, with one lane' do
      a = alloc(voices: 1, spares: 2)
      expect(a.mono?).to eq(true)
      expect(a.lanes.length).to eq(1)
      expect(a.spares).to eq(0)
      expect(alloc(voices: 1, mono: false).lanes.length).to eq(3)
      expect { alloc(voices: 2, mono: true) }.to raise_error(ArgumentError, /one voice/)
      expect { alloc(voices: 1, priority: :middle) }.to raise_error(ArgumentError, /middle/)
    end

    it 'plays notes played with nothing held normally' do
      a = alloc(on(60), off(60), on(62), off(62), voices: 1)
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'on62@2', 'off62@3']])
    end

    it 'plays new notes legato while one is held, returning to held notes (:last)' do
      a = alloc(on(60), on(64), on(67), off(67), off(60), off(64), voices: 1)
      expect(lanes(a)).to eq([[
        'on60@0',
        'off60@1', 'leg64@1',
        'off64@2', 'leg67@2',
        'off67@3', 'leg64@3',
        'off64@5',
      ]])
      expect(a.lanes[0].state).to eq(:released)
    end

    it 'keeps the velocity of the note it returns to' do
      a = alloc(on(60, 0.25), on(64, 0.75), off(64), voices: 1)
      out = a.lanes[0].reader.next(1)
      expect(out.select(&:note_on?).map { |e| [e.note, e.velocity, e.legato?] }).to eq([[60, 0.25, false], [64, 0.75, true], [60, 0.25, true]])
    end

    it 'plays the lowest held note with priority :low' do
      a = alloc(on(60), on(64), on(55), off(55), off(60), off(64), voices: 1, priority: :low)
      expect(lanes(a)).to eq([['on60@0', 'off60@2', 'leg55@2', 'off55@3', 'leg60@3', 'off60@4', 'leg64@4', 'off64@5']])
    end

    it 'plays the highest held note with priority :high' do
      a = alloc(on(60), on(55), on(64), off(64), off(55), off(60), voices: 1, priority: :high)
      expect(lanes(a)).to eq([['on60@0', 'off60@2', 'leg64@2', 'off64@3', 'leg60@3', 'off60@5']])
    end

    it 'sends poly pressure only for the sounding note' do
      a = alloc(on(60), on(64), ev.poly_pressure(60, 1), ev.poly_pressure(64, 1), voices: 1)
      expect(lanes(a)[0].last(2)).to eq(['leg64@1', 'poly_pressure@3'])
    end

    it 'counts overlapping notes on the same key' do
      a = alloc(on(60), on(60), off(60), off(60), voices: 1)
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'leg60@1', 'off60@3']])
    end

    it 'releases or chokes the note at all notes off or all sound off' do
      a = alloc(on(60), on(64), ev.cc(123, 0), off(64), on(62), voices: 1)
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'leg64@1', 'off64@2', 'cc123@2', 'on62@4']])

      b = alloc(on(60), ev.cc(120, 0), off(60), voices: 1)
      expect(lanes(b)).to eq([['on60@0', 'choke60@1', 'cc120@1']])
    end

    it 'sends channel-wide events' do
      a = alloc(on(60), ev.cc(1, 1), ev.bend(1), voices: 1)
      expect(lanes(a)).to eq([['on60@0', 'cc1@1', 'bend@2']])
    end
  end

  describe 'glide modes' do
    it 'defaults to :last' do
      expect(MB::Sound::MIDI::Allocator.new(stream).glide_mode).to eq(:last)
    end

    it 'tells free and released lanes to glide from the last note played (:last)' do
      a = alloc(on(60), off(60), on(64), on(67), voices: 3, spares: 0, glide_mode: :last)
      expect(lanes(a)).to eq([
        ['on60@0', 'off60@1', 'glide64@2', 'glide67@3'],
        ['glide60@0', 'on64@2'],
        ['glide60@0', 'glide64@2', 'on67@3'],
      ])
    end

    it 'skips sounding and choking lanes (:last)' do
      a = alloc(on(60), on(62), on(64), voices: 2, spares: 1, glide_mode: :last)
      expect(lanes(a)).to eq([
        ['on60@0', 'choke60@2'],
        ['glide60@0', 'on62@1'],
        ['glide60@0', 'glide62@1', 'on64@2'],
      ])
    end

    it 'sends glides on retriggers too (:last)' do
      a = alloc(on(60), off(60), on(60), voices: 1, spares: 1, mono: false, glide_mode: :last)
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'on60@2'], ['glide60@0', 'glide60@2']])
    end

    it 'sends no glide events with :voice or nil (or :off)' do
      [:voice, nil, :off].each do |mode|
        a = alloc(on(60), off(60), on(64), voices: 2, spares: 0, glide_mode: mode)
        expect(lanes(a)).to eq([['on60@0', 'off60@1'], ['on64@2']])
      end
      expect { alloc(glide_mode: :fast) }.to raise_error(ArgumentError, /fast/)
    end

    it 'does not hold back idle checks' do
      a = alloc(on(60), off(60), on(62), off(62), on(64), voices: 2, spares: 1, glide_mode: :last)
      a.lanes.each { |l| l.idle_check = -> { true } }
      expect(lanes(a, step: 1/100r).map { |l| l.grep(/choke/) }).to eq([[], [], []])
    end

    it 'sends no glide events in mono mode' do
      a = alloc(on(60), on(64), voices: 1, glide_mode: :last)
      expect(lanes(a)).to eq([['on60@0', 'off60@1', 'leg64@1']])
    end
  end

  describe 'invariants' do
    # Random balanced note events on two channels, with some overlapping
    # notes on the same key.
    def random_events(seed, count: 300)
      rng = Random.new(seed)
      held = []
      count.times.map do
        if !held.empty? && (held.length > 6 || rng.rand < 0.45)
          ch, n = held.delete_at(rng.rand(held.length))
          off(n, ch: ch)
        else
          key = [rng.rand(2), 50 + rng.rand(8)]
          held << key
          on(key[1], rng.rand, ch: key[0])
        end
      end + held.map { |ch, n| off(n, ch: ch) }
    end

    [[4, 2, :last], [3, 0, :last], [2, 1, :voice], [1, 2, :last]].each do |voices, spares, glide|
      it "never puts two notes on a lane and ends every note (#{voices} voices, #{spares} spares)" do
        [1, 2, 3].each do |seed|
          a = MB::Sound::MIDI::Allocator.new(stream(*random_events(seed)), voices: voices, spares: spares, glide_mode: glide, mono: false)
          a.lanes.each_with_index { |l, idx| l.idle_check = -> { idx.even? } }
          readers = a.lanes.map(&:reader)
          logs = Array.new(readers.length) { [] }
          400.times { readers.each_with_index { |r, idx| logs[idx].concat(r.next(1/100r)) } }

          logs.each do |log| expect_one_note_at_a_time(log) end

          expect(a.lanes.map(&:state) - [:free, :released, :choking]).to eq([])
          expect(logs.sum { |l| l.count(&:note_on?) }).to eq(random_events(seed).count(&:note_on?))
        end
      end
    end
  end
end
