# ux-fix-1 item 10: renders of one section say what the pre-roll does, a
# targeted render prints its song's log once, Ctrl-C keeps the partial file.
RSpec.describe(MB::Sound::RenderProgress) do
  after { MB::Sound.rewind }

  # A node that raises Interrupt (as Ctrl-C would) on its +at+th buffer.
  let(:interrupting) {
    stub_const('InterruptingNode', Class.new do
      include MB::Sound::GraphNode
      include MB::Sound::GraphNode::SampleRateHelper

      def initialize(at)
        @at = at
        @calls = 0
        @sample_rate = 48000.0
      end

      def sources = {}

      def sample(count)
        @calls += 1
        raise Interrupt if @calls == @at
        Numo::SFloat.zeros(count)
      end
    end)
  }

  it 'keeps the partial file and says so when Ctrl-C stops a render' do
    path = tmp_path('partial.flac')
    seconds = nil
    expect {
      seconds = MB::Sound.render(path, interrupting.new(11), seconds: 10, loudness: false)
    }.to output(/render stopped at 0:00\.2 \(Ctrl-C\): .*partial\.flac keeps the 0\.2 seconds rendered so far/).to_stderr
    expect(seconds).to eq(8000 / 48000.0)
    expect(MB::Sound.read(path)[0].length).to eq(8000)
  end

  it "prints what a targeted render's song prints once, not again in the second pass" do
    path = tmp_path('twice.flac')
    expect {
      MB::Sound.render(path, bars: 1, master: :club) {
        MB::Sound.at_bar(1) { puts 'the drop' }
        MB::Sound.bg 110.hz.saw.at(-12.db)
      }
    }.to output(/\A(?:(?!the drop).)*the drop\n(?:(?!the drop).)*\z/m).to_stdout
  end

  it 'mentions the faster seek before a long pre-roll, and draws no progress into a pipe' do
    path = tmp_path('late.flac')
    expect {
      MB::Sound.render(path, from: 12, bars: 1, loudness: false) { MB::Sound.bg 110.hz.saw.at(-12.db) }
    }.to output(/\A\S*render: playing bars 1-11 unheard first.*preroll: false.*\n\z/).to_stderr
  end

  # ux-fix-1 item 20
  it 'says how to replace an existing file, and prints what it rendered at the console' do
    path = tmp_path('again.flac')
    MB::Sound.render(path, 220.hz.saw.at(-20.db), seconds: 0.05)
    expect { MB::Sound.render(path, 220.hz.saw.at(-20.db), seconds: 0.05) }
      .to raise_error(MB::Util::FileMethods::FileExistsError, "#{path} exists; overwrite: true replaces it (scripts: -f)")
    old = MB::Sound.live?
    MB::Sound.live = true
    expect { MB::Sound.render(path, 220.hz.saw.at(-20.db), seconds: 0.05, overwrite: true) }.to output("rendered 0.05 s to #{path}\n").to_stdout
  ensure
    MB::Sound.live = old
  end

  it 'redraws one line in a terminal' do
    io = StringIO.new
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    p = described_class.new(session, label: 'x.flac', io: io, animate: true)
    p.update(:preroll, target: :drop)
    p.update(:render, frames: 48000) # (a new phase draws at once)
    p.clear
    expect(io.string).to eq("\r\e[Krender x.flac  pre-roll bar 1 → :drop\r\e[Krender x.flac  bar 1  0:01.0 written\r\e[K")
  ensure
    session&.close
  end
end
