# render(from:, to:, preroll:) (MB::Sound::RenderWindow): one part of a song
# on the song's own timeline.
RSpec.describe(MB::Sound::RenderWindow) do
  after { MB::Sound.rewind }

  # A small song with a form at +bpm+: a held-note synth through a reverb
  # (tails and held notes cross the section edges), a pick drawing from the
  # form's seed, and a 2/4 bar (a meter change) before the drop.
  def song(bpm: 168)
    MB::Sound.bpm bpm
    set = MB::Sound::Session.current.arrangement
    set.track(:lead) { |c| c.synth(voices: 4) { |v| v.hz.saw.lp4(1200) * v.env(0.01, 0.3, 0.5, 0.8) }.at(-12.db).reverb(:room, mix: 0.3) }
    set.track(:hum) { |c| c.tone.triangle * c.amp_env * 0.2 }
    set.scene(:intro, lead: MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n4.loop, hum: MB::Sound.seq(MB::Sound::C3).n1.loop)
    set.scene(:gap, lead: MB::Sound.seq(MB::Sound::G4).n4.loop) { MB::Sound.meter 2, 4 }
    set.scene(:drop, lead: MB::Sound.seq(MB::Sound::A3, MB::Sound::C4, MB::Sound::E4).n8.loop, hum: MB::Sound.seq(MB::Sound::A2).n2.loop) { MB::Sound.meter 4, 4 }
    set.scene(:outro, lead: MB::Sound.seq(MB::Sound::G3).n2.loop)
    MB::Sound.flow(seed: 5, on: :now) do
      intro 2
      gap 1
      drop 2
      pick :drop, :intro
      outro 2
    end
  end

  def render(path, **opts)
    MB::Sound.render(path, overwrite: true, gain: 1, **opts) { song(**opts.slice(:bpm)) }
  ensure
    MB::Sound.rewind
  end

  def frame_of(pos, bpm: 168)
    (pos * 240 / bpm.to_r * 48000).floor
  end

  let(:full) {
    path = tmp_path('full.flac')
    MB::Sound.render(path, overwrite: true, gain: 1, bars: 6) { song }
    MB::Sound.rewind
    MB::Sound.read(path)
  }

  it 'renders a section with the song\'s own samples from the frame where it starts (a pre-roll)' do
    win = tmp_path('drop.flac')
    MB::Sound.render(win, overwrite: true, gain: 1, from: :drop, bars: 2) { song }
    data = MB::Sound.read(win)

    # intro 2 bars, gap a 2/4 bar: the drop starts at 2.5 whole notes
    start = frame_of(5/2r)
    # From the frame holding the drop's start to the last frame before
    # its end
    expect(data[0].length).to eq(((5/2r + 2) * 240 / 168r * 48000).ceil - start)
    data.each_with_index do |c, i|
      expect(c).to eq(full[i][start...(start + c.length)])
    end
    expect(data[0].abs.max).to be > 0.01
  end

  [128, 367].each do |size|
    it "is exact at #{size}-sample buffers too, against a whole render at that size" do
      ref = tmp_path('ref.flac')
      MB::Sound.render(ref, overwrite: true, gain: 1, bars: 5, buffer_size: size) { song }
      MB::Sound.rewind
      win = tmp_path('win.flac')
      MB::Sound.render(win, overwrite: true, gain: 1, from: 4, bars: 1, buffer_size: size) { song }
      MB::Sound.rewind
      a = MB::Sound.read(ref)
      b = MB::Sound.read(win)
      start = frame_of(5/2r) # bar 4: after intro (2) and the 2/4 bar
      expect(b[0]).to eq(a[0][start...(start + b[0].length)])
    end
  end

  it 'counts bars: from the window\'s start, through the meter map' do
    win = tmp_path('gap.flac')
    MB::Sound.render(win, overwrite: true, gain: 1, from: :gap, bars: 2) { song }
    MB::Sound.rewind
    # bar 3 is the 2/4 gap (half a whole note), bar 4 a 4/4 bar
    expect(MB::Sound.read(win)[0].length).to eq(((2 + 3/2r) * 240 / 168r * 48000).ceil - frame_of(2))
  end

  it 'ends where to: starts (a section, or a bar number), the form\'s pick included' do
    a = tmp_path('a.flac')
    MB::Sound.render(a, overwrite: true, gain: 1, from: :drop, to: :outro) { song }
    MB::Sound.rewind
    b = tmp_path('b.flac')
    MB::Sound.render(b, overwrite: true, gain: 1, from: :drop, to: 8) { song }
    MB::Sound.rewind
    # drop 2 + the pick (drop or intro, 2 bars) = 4 bars, outro at bar 8
    expect(MB::Sound.read(a)[0].length).to eq(MB::Sound.read(b)[0].length)
    expect(MB::Sound.read(a)[0].length).to eq(((5/2r + 4) * 240 / 168r * 48000).ceil - frame_of(5/2r))
  end

  it 'renders to: from the start without from:' do
    a = tmp_path('a.flac')
    MB::Sound.render(a, overwrite: true, gain: 1, to: :drop) { song }
    MB::Sound.rewind
    expect(MB::Sound.read(a)[0].length).to eq((5/2r * 240 / 168r * 48000).ceil)
  end

  it 'seeks there with preroll: false (fresh state: no tail from before)' do
    win = tmp_path('seek.flac')
    MB::Sound.render(win, overwrite: true, gain: 1, from: :drop, bars: 1, preroll: false) { song }
    MB::Sound.rewind
    data = MB::Sound.read(win)
    expect(data[0].length).to eq((240 / 168r * 48000).ceil)
    start = frame_of(5/2r)
    # The pre-roll render carries the gap's reverb tail; the seek doesn't
    expect(data[0][0...200]).not_to eq(full[0][start...(start + 200)])
    expect(data[0].abs.max).to be > 0.01
  end

  it 'writes stems from the window\'s first frame, summing to the mix' do
    dir = tmp_path('stems')
    win = tmp_path('drop.flac')
    MB::Sound.render(win, overwrite: true, gain: 1, from: :drop, bars: 1, stems: dir, stem_format: 'wav') { song }
    MB::Sound.rewind
    mix = MB::Sound.read(win)
    stems = Dir[File.join(dir, '*.wav')].sort.map { |f| MB::Sound.read(f) }
    expect(stems.map { |s| s[0].length }.uniq).to eq([mix[0].length])
    sum = stems.map { |s| s[0] }.reduce(:+)
    expect((sum - mix[0]).abs.max).to be < 1e-4
  end

  it 'says what is wrong with a misspelled or missing target' do
    expect { render(tmp_path('x.flac'), from: :dorp, bars: 1) }.to raise_error(ArgumentError, /from: no section.*:dorp.*Did you mean\?\s+:drop/m)
    expect { render(tmp_path('x.flac'), from: 0, bars: 1) }.to raise_error(ArgumentError, /from: is a section.*bar number from 1/)
    expect { render(tmp_path('x.flac'), from: :drop, to: :drop, bars: 1) }.to raise_error(ArgumentError, /to: or bars:/)
    expect { render(tmp_path('x.flac'), from: 40, bars: 1) }.to raise_error(ArgumentError, /from: 40.*ended/)
  end

  describe MB::Sound::ScriptRunner do
    it 'renders --from SECTION --to SECTION, and --from BAR with --bars' do
      out = tmp_path('song.flac')
      r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--from', 'drop', '--to', 'outro'], script: 'bin/example.rb')
      expect { r.run_song(bars: 10) { song } }.to output(/Rendered/).to_stdout
      MB::Sound.rewind
      a = MB::Sound.read(out)
      # The reference at the script's master gain (the default -10 dB)
      whole = tmp_path('whole.flac')
      MB::Sound.render(whole, bars: 6) { song }
      MB::Sound.rewind
      ref = MB::Sound.read(whole)
      start = frame_of(5/2r)
      expect(a[0][0...48000]).to eq(ref[0][start...(start + 48000)])

      r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '-f', '--from', '4', '--bars', '0.5'], script: 'bin/example.rb')
      expect { r.run_song(bars: 10) { song } }.to output(/Rendered/).to_stdout
      MB::Sound.rewind
      b = MB::Sound.read(out)
      start = frame_of(5/2r) # bar 4 is the drop's first bar
      expect(b[0][0...1000]).to eq(ref[0][start...(start + 1000)])
    end

    it 'renders to the end of the song\'s bars with --from alone' do
      out = tmp_path('song.flac')
      r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--from', '4'], script: 'bin/example.rb')
      expect { r.run_song(bars: 5) { MB::Sound.bpm 168; MB::Sound.bg(:t, 220.hz.sine.at(0.1), fade: 0) } }.to output(/Rendered/).to_stdout
      MB::Sound.rewind
      expect(MB::Sound.read(out)[0].length).to eq((5 * 240 / 168r * 48000).ceil - frame_of(3))
    end

    it 'refuses --seek without --from and --to with --bars' do
      out = tmp_path('song.flac')
      r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--seek'], script: 'bin/example.rb')
      expect { r.run_song(bars: 2) { song } }.to raise_error(ArgumentError, /--seek goes with --from/)
      r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--to', '3', '--bars', '1'], script: 'bin/example.rb')
      expect { r.run_song(bars: 2) { song } }.to raise_error(ArgumentError, /--to or --bars/)
    end
  end
end
