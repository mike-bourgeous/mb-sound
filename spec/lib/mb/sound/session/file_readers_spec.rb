# A Session closes the file readers of the graphs it played when it closes
# (fix-batch-1106): a graph cut short (until, stop, replacement) left its
# ffmpeg blocked on a full pipe until the GC closed the pipe
# (fix-flaky-1104 found 19 such children in a suite run;
# spec/support/child_guard.rb now fails an example that leaves one).
RSpec.describe(MB::Sound::Session, 'file readers') do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false) }

  after do
    session.close
    MB::Sound.rewind
  end

  def running_children
    MB::Sound::Starter.current&.child_list&.count { |c| Array(c[:argv]).flatten.join(' ').include?('drums.flac') }
  end

  it 'closes a reader cut short by until when it closes, and leaves it open while it runs' do
    input = MB::Sound.file_input('sounds/drums.flac')
    session.add(input.until(0.1), on: :now)
    20.times { session.process_buffer }
    expect(session.players).to be_empty # (ended by until, 0.1 s of a longer file)
    expect(input.closed?).to eq(false)
    expect(running_children).to eq(1) if MB::Sound::Starter.current

    session.close
    expect(input.closed?).to eq(true)
    expect(running_children).to eq(0) if MB::Sound::Starter.current
  end

  it 'closes the readers of stopped and playing graphs, and a played file' do
    a = MB::Sound.file_input('sounds/drums.flac')
    session.add(a, on: :now, name: :a)
    session.add('sounds/drums.flac', on: :now, name: :b)
    4.times { session.process_buffer }
    session.remove(:a)
    4.times { session.process_buffer }

    session.close
    expect(a.closed?).to eq(true)
    expect(running_children).to eq(0) if MB::Sound::Starter.current
  end

  it 'leaves inputs that read no process alone' do
    input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(48000)])
    session.add(input, on: :now)
    2.times { session.process_buffer }
    session.close
    expect(input.sample(10).length).to eq(10)
  end
end
