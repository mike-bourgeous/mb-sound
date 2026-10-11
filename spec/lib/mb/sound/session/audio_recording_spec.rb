RSpec.describe(MB::Sound::Session::AudioRecording) do
  # 120 BPM at 48kHz: one bar is 96000 frames
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session(channels: 2)
    transport = MB::Sound::Sequence::Transport.new(bpm: 120)
    out = MB::Sound::NullOutput.new(channels: channels, sleep: false)
    MB::Sound::Session.new(master_gain: 0.5, output: out, transport: transport, channels: channels, buffer_size: 800, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  # An output that keeps what is written.
  class AudioRecordingKeepOutput
    attr_reader :buffers, :closed

    def initialize
      @buffers = []
    end

    def write(bufs)
      @buffers << bufs
    end

    def close
      @closed = true
    end

    def channel(c)
      @buffers.map { |b| b[c] }.reduce(:concatenate)
    end
  end

  def render(session, frames, sizes)
    out = []
    left = frames
    sizes.cycle do |n|
      break if left <= 0
      n = [n, left].min
      out << session.process_buffer(n)[0].dup
      left -= n
    end
    out.reduce(:concatenate)
  end

  it 'records the master bus from the exact start frame to the exact stop frame at any buffer size' do
    [[800], [367, 368], [64], [1001, 13]].each do |sizes|
      s = new_session
      keep = AudioRecordingKeepOutput.new
      s.add(MB::Sound.noise.at(0.5), name: :noise, on: :now)
      s.record_audio('unused.flac', output: keep, start_time: 1/4r) # frame 24000
      s.stop_recording(start_time: 5/8r)                            # frame 60000
      mix = render(s, 96000, sizes)
      r = s.recordings.first
      r.wait

      expect(r.start_frame).to eq(24000)
      expect(r.stop_frame).to eq(60000)
      expect(r.frames).to eq(36000)
      expect(keep.closed).to eq(true)
      expect(keep.channel(0)).to eq(mix[24000...60000])
      expect(r.peak).to be_within(1e-6).of(keep.channel(0).abs.max)
      expect(s.journal.changes.map(&:kind)).to include(:record, :stop_record, :recorded)
    end
  end

  it 'writes a file whose length and level match the mix' do
    path = tmp_path('take.flac')
    s = new_session
    s.add(0.5.constant, name: :dc, on: :now)
    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.rec(path) }.to output(/Recording the master bus to .*take\.flac/).to_stdout
    end
    render(s, 4800, [800])
    MB::Sound::Session.with_context(session: s) { MB::Sound.stop_rec }
    render(s, 1600, [800])
    s.recordings.first.wait

    data = MB::Sound.read(path)
    expect(data.length).to eq(2)
    expect(data[0].length).to eq(4800)
    expect(data[0].max).to be_within(1e-4).of(0.25) # master gain 0.5
    expect(data[0].min).to be_within(1e-4).of(0.25)

    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.rec(path) }.to raise_error(ArgumentError, /exists/)
    end
  end

  it 'writes nothing while a take replays, but still makes the change' do
    s = new_session
    c = MB::Sound::Session.with_perform(session: s, source: :replay) { s.record_audio('/nonexistent/x.flac') }
    expect(c.entry.data[:replay]).to eq(true)
    expect(s.recordings).to be_empty
  end
end
