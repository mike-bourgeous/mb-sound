# Holds (ux-notes-2, the maintainer's "Arm + hold the clip"): `hold :lead`
# silences a track's clip, cue player, and wired stream while its live
# monitor plays on; `unhold` brings the clip back in time, as unmute does.
RSpec.describe(MB::Sound::Session::Holds, :aggregate_failures) do
  # 120 BPM at 48kHz: a quarter note is 24000 frames
  let(:ev) { MB::Sound::MIDI::Event }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session
    transport = MB::Sound::Sequence::Transport.new(bpm: 120)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  # A stand-in keyboard: [note, on seconds, off seconds].
  def keyboard(*notes)
    events = notes.flat_map { |n, on, off| [ev.parse([0x90, n, 100], time: on.to_r), ev.parse([0x80, n, 64], time: off.to_r)] }
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
  end

  # Runs +lines+ (frame => console lines, run before the buffer starting
  # at or after the frame) in buffers of +sizes+ for +frames+ frames.
  # Returns the output.
  def perform(session, lines, frames, sizes = [800])
    b = MB::Sound::Take.console_binding
    pending = lines.sort.to_h
    out = []
    done = 0
    sizes.cycle do |n|
      break if done >= frames
      pending.keys.select { |f| f <= done }.each do |f|
        pending.delete(f).each { |code| MB::Sound::Session.with_context(session: session) { b.eval(code) } }
      end
      n = [n, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    SpecBuffers.join(out)
  end

  def setup_lines = ['track(:lead, q: 1) { |c| c.number * c.gate }', 'riff = seq(C4, E4, G4, nil).n4.loop.named(:riff)', 'bg :lead, riff, on: :now']

  [[800], *SlowTier.slow_tier([[367, 368], [64]])].each do |sizes|
    it "silences the clip while the monitor plays the keyboard, and unhold brings the clip back in time as unmute does (#{sizes.join('/')}-frame buffers)" do
      held = new_session
      held.midi_in.input = keyboard([50, 1.5, 1.9])
      a = perform(held, { 0 => [*setup_lines, 'arm :lead'], 30_000 => ['hold :lead'], 150_000 => ['unhold :lead'] }, 240_000, sizes)

      muted = new_session
      b = perform(muted, { 0 => setup_lines, 30_000 => ['mute :lead'], 150_000 => ['unmute :lead'] }, 240_000, sizes)

      # Held: the clip is gone (the keyboard's D3 alone, through the monitor)
      expect(a[40_000...72_000].abs.max).to eq(0)
      expect(a[73_000...91_000].to_a.uniq).to eq([50.0])
      expect(a[92_000...150_000].abs.max).to eq(0)
      # Everything else as a mute and unmute: the ramps, and the clip back
      # in phase (G4 at 2.5 s, then the riff from its start at bar 2)
      diff = (a - b).abs
      diff[72_000...92_000] = 0 # (the keyboard's note)
      expect(diff.max).to eq(0)
      expect(a[193_000...215_000].to_a.uniq).to eq([60.0])
      expect(held.journal.changes.map(&:kind)).to include(:hold, :unhold)
    end
  end

  it 'leaves the monitor audible and the track and its cue player silent while held' do
    s = new_session
    s.midi_in.input = keyboard
    perform(s, { 0 => [*setup_lines, 'arm :lead', 'hold :lead'] }, 1600)
    expect(s.held_tracks).to eq([:lead])
    expect(s.audible?(:lead)).to eq(false)
    expect(s.audible?(:"lead/cue")).to eq(false)
    expect(s.audible?(:"lead/live")).to eq(true)
    MB::Sound::Session.with_context(session: s) do
      expect(MB::Sound.hold).to eq([:lead])
      expect(MB::Sound.tracks[:lead]).to include('playing, held (unhold brings it back), armed')
    end
    perform(s, { 0 => ['unhold'] }, 800)
    expect(s.held_tracks).to eq([])
    expect(s.audible?(:lead)).to eq(true)
  end

  it 'drops a held wire\'s stream on the hold\'s frame (its note ends there) and plays it in time when released, at any buffer size' do
    lines = { 0 => ['track(:lead, q: 1) { |c| c.number * c.gate }', 'bg :clock, 0.constant, on: :now', 'wire :lead, seq(C4, E4, G4, nil).n4.loop.stream'] }
    # (landing between buffers' starts: the hold at 1.25 s inside G4, the
    # release at 2.75 s inside E4)
    held = lines.merge(50_000 => ['hold :lead, on: 1.n8'], 121_000 => ['unhold :lead, on: 1.n8'])
    a = perform(new_session, held, 192_000)
    b = perform(new_session, lines, 192_000)

    expect(b[61_000...71_000].to_a.uniq).to eq([67.0]) # (G4 plays on without the hold)
    expect(a[48_000...60_000].to_a.uniq).to eq([67.0])
    expect(a[60_000...144_000].abs.max).to eq(0)
    # Released inside E4 (not chased): the stream in time again from its
    # next note (G4 at 3 s)
    expect(a[144_000...192_000]).to eq(b[144_000...192_000])
    expect(a[144_000...168_000].to_a.uniq).to eq([67.0])
    SlowTier.slow_tier([[367, 368], [64]]).each do |sizes|
      expect(perform(new_session, held, 192_000, sizes)).to eq(a), "#{sizes.join('/')}-frame buffers"
    end
  end

  it 'is undoable, and a launch on a held name starts held' do
    s = new_session
    perform(s, { 0 => ['track(:lead, q: 1) { |c| c.number * c.gate }', 'hold :lead'] }, 1600)
    expect(s.held_tracks).to eq([:lead])
    out = perform(s, { 0 => ['bg :lead, seq(C4).n4.loop, on: :now'] }, 4000)
    expect(out.abs.max).to eq(0)
    perform(s, { 0 => ['undo 2, on: :now'] }, 1600)
    expect(s.held_tracks).to eq([])
    MB::Sound::Session.with_context(session: s) { expect { MB::Sound.redo!(on: :now) }.not_to raise_error }
  end

  it 'has console names that are ArrangementMethods, not Kernel, Object, GraphNode, or Pry names' do
    require 'pry'
    pry_commands = Pry::Commands.keys.map(&:to_s)
    %i[hold hold_track unhold unhold_track].each do |n|
      expect(MB::Sound.method(n).owner).to eq(MB::Sound::ArrangementMethods), "#{n} is defined by #{MB::Sound.method(n).owner}"
      expect(Object.new.respond_to?(n, true)).to eq(false), "#{n} is an Object method"
      expect(pry_commands).not_to include(n.to_s)
      expect(MB::Sound::GraphNode.method_defined?(n)).to eq(false), "#{n} is a GraphNode method"
    end
  end
end
