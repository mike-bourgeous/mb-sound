# render(from:, to:, preroll:) (MB::Sound::RenderWindow): one part of a song
# on the song's own timeline.
RSpec.describe(MB::Sound::RenderWindow) do
  after { MB::Sound.rewind }

  include RenderWindowSong

  def render(path, **opts)
    MB::Sound.render(path, overwrite: true, gain: 1, **opts) { song(**opts.slice(:bpm)) }
  ensure
    MB::Sound.rewind
  end


  # The whole song, rendered once for the examples that compare with it
  before(:all) do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'full.flac')
      MB::Sound.render(path, overwrite: true, gain: 1, bars: 6) { song }
      MB::Sound.rewind
      @full = MB::Sound.read(path)
    end
  end

  let(:full) { @full }

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

  [367].each do |size|
    it "is exact at #{size}-sample buffers too, against a whole render at that size" do
      ref = tmp_path('ref.flac')
      MB::Sound.render(ref, overwrite: true, gain: 1, bars: 4, buffer_size: size) { song }
      MB::Sound.rewind
      win = tmp_path('win.flac')
      MB::Sound.render(win, overwrite: true, gain: 1, from: 4, bars: 0.5, buffer_size: size) { song }
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
    MB::Sound.render(b, overwrite: true, gain: 1, from: :drop, to: 5) { song }
    MB::Sound.rewind
    # drop 2 + the pick (drop or intro, 2 bars) = 4 bars, outro at bar 8
    expect(MB::Sound.read(a)[0].length).to eq(((5/2r + 4) * 240 / 168r * 48000).ceil - frame_of(5/2r))
    # Bar 5 starts a bar after the drop (bar 4)
    expect(MB::Sound.read(b)[0].length).to eq(((5/2r + 1) * 240 / 168r * 48000).ceil - frame_of(5/2r))
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
    # The pre-roll render carries the gap's echoes; the seek doesn't
    expect(data[0][0...14400]).not_to eq(full[0][start...(start + 14400)])
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
end
