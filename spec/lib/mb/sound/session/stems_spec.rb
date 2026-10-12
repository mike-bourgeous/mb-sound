RSpec.describe(MB::Sound::Session::Stems) do
  after { MB::Sound.rewind }

  # Two named parts (one starting late and ending early) and an unnamed one
  def song
    MB::Sound.bpm 120
    MB::Sound.bg :bass, 110.hz.ramp * 0.2, fade: 0
    MB::Sound.bg :keys, (330.hz.triangle * 0.1).until(0.5.bars), fade: 0, at: MB::Sound.bar(2)
    MB::Sound.bg 880.hz.sine * 0.05, fade: 0
  end

  def read(path)
    MB::Sound.read(path).map { |c| Numo::DFloat.cast(c) }
  end

  it 'writes one aligned file per player that sums to the mix' do
    dir = tmp_path('stems')
    MB::Sound.render(tmp_path('mix.flac'), bars: 3, stems: dir) { song }

    files = Dir[File.join(dir, '*')].map { |f| File.basename(f) }.sort
    expect(files.length).to eq(3)
    expect(files).to include('bass.flac', 'keys.flac')
    expect(files.grep(/\Aplayer_\d+\.flac\z/).length).to eq(1)

    mix = read(tmp_path('mix.flac'))
    stems = files.map { |f| read(File.join(dir, f)) }
    stems.each { |s| expect(s.map(&:length)).to eq(mix.map(&:length)) }

    sum = mix.map.with_index { |_, c| stems.map { |s| s[c] }.reduce(:+) }
    2.times { |c| expect((sum[c] - mix[c]).abs.max).to be < 1e-4 }

    # The late part is silent until its bar (2 s at 120 BPM), then plays
    # half a bar
    keys = read(File.join(dir, 'keys.flac'))[0]
    bar = 96000
    expect(keys[0...bar].abs.max).to eq(0)
    expect(keys[bar...(bar + 24000)].abs.max).to be > 0.02 # 0.1 at the -10 dB master gain
    expect(keys[(bar + 48000)..].abs.max).to eq(0)
  end

  it 'leaves the mix unchanged' do
    MB::Sound.render(tmp_path('plain.flac'), bars: 2) { song }
    MB::Sound.rewind
    MB::Sound.render(tmp_path('with.flac'), bars: 2, stems: tmp_path('s')) { song }
    expect(read(tmp_path('with.flac'))).to eq(read(tmp_path('plain.flac')))
  end

  it 'writes the parts before the master chain, times the master gain' do
    dir = tmp_path('stems')
    MB::Sound.render(tmp_path('mix.flac'), bars: 2, stems: dir, gain: 0.5) do
      song
      MB::Sound.master { |m| m * 0.25 }
    end

    mix = read(tmp_path('mix.flac'))
    stems = Dir[File.join(dir, '*.flac')].map { |f| read(f) }
    sum = stems.map { |s| s[0] }.reduce(:+)
    # The chain's gain applies to the mix only
    n = MB::M.min(mix[0].length, sum.length)
    expect((sum[0...n] * 0.25 - mix[0][0...n]).abs.max).to be < 1e-4
  end

  it 'takes the stem format from the mix file or stem_format:' do
    dir = tmp_path('stems')
    MB::Sound.render(tmp_path('mix.wav'), bars: 1, stems: dir) { MB::Sound.bg :tone, 220.hz.sine * 0.1, fade: 0 }
    MB::Sound.rewind
    MB::Sound.render(tmp_path('mix2.flac'), bars: 1, stems: dir, stem_format: 'mp3') { MB::Sound.bg :tone, 220.hz.sine * 0.1, fade: 0 }
    expect(Dir[File.join(dir, '*')].map { |f| File.basename(f) }.sort).to eq(['tone.mp3', 'tone.wav'])
  end
end
