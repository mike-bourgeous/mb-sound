# Renders end on the exact frame (session-2, the maintainer's "Exact
# frame", 2026-10-31): when their sounds end, when master or bus tails go
# quiet, when a script's ring-down completes, and where a replaced master
# chain's tail is dropped, so a file is the same length (and the same
# samples) at any buffer size.  design/notes/graph_nodes.md, "Exact render
# ends".
RSpec.describe('exact render ends', :aggregate_failures) do
  SIZES = [800, 367, 128].freeze

  def render_at(size, channels: 1, **options, &block)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: channels, buffer_size: size)
    seconds = MB::Sound.render(out, buffer_size: size, channels: channels, gain: 1, **options, &block)
    data = out.captured.map { |c| Numo::SFloat.cast(c) }
    expect((seconds * 48000).round).to eq(data[0].length)
    data
  end

  # Renders +block+ at every size of SIZES; expects the same length and
  # samples (within +tolerance+); returns the 800-frame render's first
  # channel.
  def expect_exact(tolerance: 0, **options, &block)
    renders = SIZES.map { |size| render_at(size, **options, &block) }
    lengths = renders.map { |r| r[0].length }
    expect(lengths.uniq.length).to eq(1), "lengths at #{SIZES.join('/')} frames: #{lengths.join(', ')}"
    renders.drop(1).each_with_index do |r, i|
      n = [r[0].length, renders[0][0].length].min
      expect((r[0][0...n] - renders[0][0][0...n]).abs.max).to be <= tolerance, "#{SIZES[i + 1]}-frame buffers differ"
    end
    renders[0][0]
  end

  it 'ends a render on the frame its last sound ended, not at the end of the buffer holding it' do
    data = expect_exact { MB::Sound.bg(:a, 220.hz.sine.at(0.1).until(0.3)) }
    expect(data.length).to eq(14400)
  end

  it 'ends master and bus tails on the frame their quiet second completes' do
    verb = expect_exact {
      MB::Sound.master { |m| m.reverb(:room, mix: 0.3) }
      MB::Sound.bg(:a, 220.hz.sine.at(0.1).until(0.3))
    }
    q = MB::Sound::QuietRun::QUIET
    last = (verb.abs.ge(q)).where[-1]
    expect(verb.length).to eq(last + 1 + 48000)

    echo = expect_exact {
      MB::Sound.bus(:v) { |s| s.delay(0.2, feedback: 0.5) }
      MB::Sound.bg(:a, 220.hz.sine.at(0.1).until(0.3), send: { v: 0.5 })
    }
    expect(echo.length).to eq(echo.abs.ge(q).where[-1] + 1 + 48000)
  end

  it 'keeps time for a scheduled block up to its frame' do
    data = expect_exact(bars: 3, bpm: 120) {
      MB::Sound.bg(:a, 0.25.constant.until(0.5))
      MB::Sound.every(1) {}
    }
    expect(data.length).to eq(4 * 48000) # (bar 3's block; bar 4 is the end)
  end

  it "ends a script's ring-down on the frame its quiet second completes (Session#end_after)" do
    data = expect_exact {
      input = MB::Sound.file_input('spec/test_data/arp_a7.flac', channels: 1).ringdown
      MB::Sound.bg(:script, input.delay(0.2, feedback: 0.5, dry: 1), fade: 0)
      expect(MB::Sound::Session.current.end_after(:script, [input])).to eq(1)
    }
    expect(data.length).to eq(data.abs.ge(MB::Sound::QuietRun::QUIET).where[-1] + 1 + 48000)
  end

  it "caps a ring-down's tail at end_after's max_tail:, or leaves it to the render's limit" do
    input_frames = MB::Sound.read('spec/test_data/arp_a7.flac')[0].length
    stop = (input_frames / 800 + 1) * 800 # (the sleep grid frame after the input ended)
    drone = ->(**opts) {
      input = MB::Sound.file_input('spec/test_data/arp_a7.flac', channels: 1).ringdown
      MB::Sound.bg(:script, input + 0.1.constant, fade: 0)
      expect(MB::Sound::Session.current.end_after(:script, [input], **opts)).to eq(1)
    }

    capped = expect_exact { drone.(max_tail: 0.5) }
    fade_end = stop + 24000 + (MB::Sound::Session::Master::TAIL_FADE_SECONDS * 48000).round
    expect(capped[stop + 23000]).to be_within(1e-6).of(0.1)
    expect(capped.length).to eq(fade_end) # (the cap fade ends the player)
    expect(capped[-1].abs).to be < 1e-4

    open = render_at(800, max_seconds: 12) { drone.(max_tail: Float::INFINITY) }[0]
    expect(open.length).to eq(12 * 48000) # (past the default 10 s cap, unfaded)
    expect(open[-1]).to be_within(1e-6).of(0.1)

    expect { MB::Sound.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), max_seconds: 0.1) { drone.(max_tail: 0) } }.to raise_error(ArgumentError, /max_tail/)
  end

  it "drops a replaced master chain's tail on its exact frame" do
    expect_exact(bars: 3, bpm: 120) {
      MB::Sound.bg(:a, 0.1.constant.until(1.5))
      MB::Sound.master { |m| m.delay(0.25, feedback: 0.3, dry: 1, wet: 1) }
      MB::Sound.at_bar(1, beat: 2) { MB::Sound.master { |m| m * 0.5 } }
    }
  end

  it 'cuts stems where the mix ends' do
    SIZES.each do |size|
      dir = tmp_path("stems_#{size}")
      data = render_at(size, stems: dir) { MB::Sound.bg(:a, 220.hz.sine.at(0.1).until(0.3)); MB::Sound.bg(:b, 0.05.constant.until(0.2)) }
      expect(data[0].length).to eq(14400)
      %w[a b].each { |n| expect(MB::Sound.read(File.join(dir, "#{n}.flac"))[0].length).to eq(14400) }
    end
  end
end
