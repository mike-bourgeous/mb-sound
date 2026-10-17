# render(report: :tracks) (MB::Sound::MixReport; panel Nev F16, Kaede 12).
RSpec.describe(MB::Sound::MixReport) do
  after { MB::Sound.rewind }

  def song
    MB::Sound.bpm 120
    set = MB::Sound::Session.current.arrangement
    set.track(:lead) { |c| c.synth(voices: 3) { |v| v.hz.saw * v.env(0.01, 0.2, 0.5, 0.3) }.at(-12.db) }
    set.track(:bass) { |c| c.tone.triangle * c.amp_env * 0.8 }
    set.scene(:a, lead: MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.loop, bass: MB::Sound.seq(MB::Sound::C2).n4.loop)
    set.scene(:b, lead: MB::Sound.seq(MB::Sound::A3, MB::Sound::C4, MB::Sound::E4).n8.loop)
    MB::Sound.flow(on: :now) do
      a 2
      b 2
      a 2
    end
  end

  # Renders with stems as float WAVs (measured exactly as written).
  def render(**opts)
    @dir = tmp_path('stems')
    @mix = tmp_path('mix.wav')
    expect {
      MB::Sound.render(@mix, overwrite: true, bars: 6, report: :tracks, stems: @dir, stem_format: 'wav', **opts) { song }
    }.to output(/Track +LUFS +ST max +dBTP +Crest/).to_stdout
    MB::Sound.rewind
    described_class.last
  end

  it 'measures every track and the mix as the loudness tools measure their files' do
    r = render
    expect(r.tracks.keys).to eq([:lead, :bass])
    { lead: 'lead.wav', bass: 'bass.wav' }.each do |name, file|
      ref = MB::Sound.loudness(File.join(@dir, file))
      row = r.tracks[name]
      expect(row.integrated).to be_within(0.02).of(ref.integrated)
      expect(row.short_term_max).to be_within(0.02).of(ref.short_term_max)
      expect(row.true_peak).to be_within(0.02).of(ref.true_peak)
    end
    ref = MB::Sound.loudness(@mix)
    expect(r.mix.integrated).to be_within(0.02).of(ref.integrated)
    expect(r.mix.true_peak).to be_within(0.02).of(ref.true_peak)

    # Crest over the time the track played (the lead, in every scene, from
    # the start; the stem file is padded with silence to the render's
    # length)
    data = MB::Sound.read(File.join(@dir, 'lead.wav')).map { |c| c[0...(r.tracks[:lead].seconds * 48000).round] }
    peak = data.map { |c| c.abs.max }.max
    rms = Math.sqrt(data.sum { |c| (Numo::DFloat.cast(c)**2).sum } / (data.length * data[0].length))
    expect(r.tracks[:lead].crest).to be_within(0.02).of(20 * Math.log10(peak / rms))
  end

  it 'measures each section pass from the frame it starts on' do
    r = render
    expect(r.sections.map(&:label)).to eq(['a', 'b', 'a 2'])
    expect(r.sections.map(&:start)).to eq([0.0, 4.0, 8.0])
    mix = MB::Sound.read(@mix)
    r.sections.each_with_index do |s, i|
      from = (s.start * 48000).round
      to = i + 1 < r.sections.length ? (r.sections[i + 1].start * 48000).round : mix[0].length
      ref = MB::Sound.loudness(mix.map { |c| c[from...to] })
      expect(s.loudness[:mix]).to be_within(0.02).of(ref.integrated), s.label
    end
    # The bass is dropped in b (ringing out), so it is much quieter there
    expect(r.sections[1].loudness[:bass]).to be < r.sections[0].loudness[:bass] - 6
  end

  it 'measures only the window of a render window' do
    r = nil
    expect {
      MB::Sound.render(tmp_path('w.wav'), overwrite: true, from: :b, to: 7, report: :tracks) { song }
    }.to output(/Section/).to_stdout
    MB::Sound.rewind
    r = described_class.last
    expect(r.sections.map(&:label)).to eq(['b', 'a 2'])
    expect(r.sections[0].start).to eq(0.0)
    expect(r.mix.seconds).to be_within(0.01).of(MB::Sound.read(tmp_path('w.wav'))[0].length / 48000.0)
  end

  it 'prints a table and a Hash' do
    r = render
    text = r.to_s
    expect(text.lines.first).to match(/\ATrack\s+LUFS\s+ST max\s+dBTP\s+Crest/)
    expect(text).to match(/^mix\s+-\d+\.\d/)
    expect(text).to match(/^Section\s+Start\s+Mix\s+Peak\s+lead\s+bass/)
    h = r.to_h
    expect(h[:tracks][:lead][:integrated]).to be_a(Float)
    expect(h[:sections].length).to eq(3)
  end

  it 'is printed by song scripts with --report' do
    out = tmp_path('song.flac')
    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--report', '--bars', '2'], script: 'bin/example.rb')
    expect { r.run_song { song } }.to output(/Track +LUFS.*^lead .*^mix .*Rendered/m).to_stdout
    MB::Sound.rewind
  end

  it 'refuses other report kinds' do
    expect { MB::Sound.render(tmp_path('x.wav'), bars: 1, report: :sections) { song } }.to raise_error(ArgumentError, /report: is :tracks/)
  end
end
