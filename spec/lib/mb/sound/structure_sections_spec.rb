# Structure analysis, phase S2: sections, letter labels, forms, :analysis
# markers, and the self-check against the form that played
# (MB::Sound::Structure::Sections, Result#sections/#form/#markers!/#compare).
RSpec.describe('MB::Sound::Structure sections', :aggregate_failures) do

  # Audio for +plan+ ([[kind, bars], ...]) at +bpm+ (4/4), built in Numo:
  # :a a kick on every beat under an A minor chord, :b eighth-note noise
  # hats over an F major chord, :c a G major chord with sixteenth clicks.
  def self.sections_audio(plan, bpm:, rate: 48000)
    beat = (60.0 / bpm * rate).round
    bar = beat * 4
    chords = { a: [57, 60, 64], b: [53, 57, 60], c: [55, 59, 62] }
    rng = Random.new(3)
    parts = plan.flat_map { |kind, bars|
      Array.new(bars) {
        t = Numo::DFloat.new(bar).seq / rate
        y = chords[kind].sum { |m| Numo::NMath.sin(t * 2 * Math::PI * 440 * 2**((m - 69) / 12.0)) } * 0.1
        case kind
        when :a
          4.times { |i| k = Numo::DFloat.new(beat).seq / rate; y[(i * beat)...((i + 1) * beat)] += Numo::NMath.sin(k * 2 * Math::PI * 55) * Numo::NMath.exp(-k * 20) * 0.6 }
        when :b
          8.times { |i| n = beat / 2; burst = Numo::DFloat.cast(Array.new(n) { rng.rand(-1.0..1.0) }) * Numo::NMath.exp(-(Numo::DFloat.new(n).seq / rate) * 60) * 0.3; y[(i * n)...((i + 1) * n)] += burst }
        when :c
          16.times { |i| n = beat / 4; y[i * n] += 0.8 }
        end
        y
      }
    }
    Numo::DFloat.hstack(parts)
  end

  def self.grid(bpm)
    MB::Sound::Sequence::Transport.new(bpm: bpm)
  end

  before(:all) do
    @bpm = 240
    @plan = [[:a, 8], [:b, 8], [:a, 8], [:c, 4], [:b, 8]]
    @result = MB::Sound::Structure.analyze(self.class.sections_audio(@plan, bpm: @bpm), grid: self.class.grid(@bpm))
  end

  it 'finds the sections on their bar lines with letter labels' do
    s = @result.sections
    expect(s.map(&:first_bar)).to eq([1, 9, 17, 25, 29])
    expect(s.map(&:bars)).to eq([8, 8, 8, 4, 8])
    expect(@result.labels).to eq(%w[A B A C B])
    expect(s.map(&:name)).to eq(%i[a b a c b])
    expect(s[1].seconds).to be_within(1e-9).of(8 * 4 * 60.0 / @bpm)
    expect(s[1].beats).to eq(32)
    expect(s[3].bar_range).to eq(25...29)
    expect(s[0].to_s).to eq('A    bar 1, 8 bars at 0:00.00')
    expect(@result.to_s).to end_with('transport, A B A C B')
    d = @result.section_details
    expect(d[:boundaries]).to eq([8, 16, 24, 28])
    expect(d[:novelty].size).to eq(@result.bars.length + 1)
    expect(d[:ssm].shape).to eq([@result.bars.length, @result.bars.length])
  end

  it 'prints the sections as a flow, which builds' do
    expect(@result.form.to_ruby).to eq("flow do\n  a 8\n  b 8\n  a\n  c 4\n  b\nend")
    code = @result.flow_ruby
    expect(code).to start_with("bpm 240\nflow do\n  a 8  # A    bar 1, 0:00.00\n")
    expect(code).to include("  c 4  # C    bar 25, 0:24.00\n")
    rebuilt = MB::Sound::Form.build { instance_eval(code.lines[2...-1].join) }
    expect(rebuilt).to eq(@result.form)
  end

  it 'merges runs into times: and labels a variant with a prime' do
    secs = [
      MB::Sound::Structure::Section.new(label: 'A', name: :a, first_bar: 1, bars: 4, seconds: 0, end_seconds: 1, beats: 16),
      MB::Sound::Structure::Section.new(label: 'A', name: :a, first_bar: 5, bars: 4, seconds: 1, end_seconds: 2, beats: 16),
      MB::Sound::Structure::Section.new(label: "A'", name: :a2, first_bar: 9, bars: 2, seconds: 2, end_seconds: 3, beats: 8),
      MB::Sound::Structure::Section.new(label: 'A', name: :a, first_bar: 11, bars: 8, seconds: 3, end_seconds: 4, beats: 32),
    ]
    expect(@result.form(secs).to_ruby).to eq("flow do\n  a 4, times: 2\n  a2 2\n  a 8\nend")
    expect(MB::Sound::Structure::Sections.name_of("B''")).to eq(:b3)
    expect(secs[2].letter).to eq('A')
  end

  it 'takes segmentation options (a costlier boundary keeps fewer)' do
    expect(@result.sections(cost: 5).length).to eq(1)
    expect(@result.sections(same: 1.01).map(&:label).uniq.length).to be >= 3
  end

  it 'compares with the form that played' do
    c = @result.compare(@plan.each_with_index.map { |(k, b), i| [:"#{k}#{i}", b] })
    expect([c.precision, c.recall, c.f]).to eq([1.0, 1.0, 1.0])
    expect(c).to be_exact
    expect(c.matched).to eq([[9, 9], [17, 17], [25, 25], [29, 29]])
    # Distinct names for every pass: labels that repeat count as wrong
    expect(c.label_precision).to be < 1

    form = MB::Sound::Form.build { a 8; b 8; a; c 4; b }
    c = @result.compare(form)
    expect(c.label_f).to eq(1.0)
    expect(c.to_s).to start_with('boundaries: 4 of 4 found within 1 bar (P 1.00, R 1.00, F 1.00); labels F 1.00')
    expect(c.to_s).to include('     25  c         C')

    off = @result.compare([[:x, 8], [:y, 4], [:z, 28]])
    expect(off.missed).to eq([13])
    expect(off.extra).to eq([17, 25, 29])
    expect(off.matched).to eq([[9, 9]])
    expect(off.to_s).to include('missed: bar 13', 'extra: bar 17, bar 25, bar 29')
    expect(off.inspect).to start_with('#<Structure::Comparison boundaries: 1 of 2')
  end

  it 'puts :analysis markers in a Session, replacing earlier ones' do
    session = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2), transport: self.class.grid(@bpm))
    session.markers.set(:"analysis/old_1", kind: :analysis, pos: 3)
    session.markers.set(:mine, kind: :position, pos: 1)
    set = @result.markers!(session: session)
    expect(set.map(&:name)).to eq(%i[analysis/a_1 analysis/b_1 analysis/a_2 analysis/c_1 analysis/b_2])
    expect(set.map(&:kind).uniq).to eq([:analysis])
    expect(set.map(&:pos)).to eq([0r, 8r, 16r, 24r, 28r])
    expect(session.markers[:"analysis/old_1"]).to be_nil
    expect(session.markers[:mine]).not_to be_nil
    expect(session.markers.info[:"analysis/c_1"]).to eq('25:1 (analysis)')

    # From bar 5 of the session, under a warning at another tempo
    session.transport.bpm = 120
    set = nil
    expect { set = @result.markers!(session: session, at: 5) }.to output(/plays at 120\.00 BPM, the analysis found 240\.00 \(`bpm 240`/).to_stderr
    expect(set.first.pos).to eq(4r)
    expect(@result.marker_names(prefix: :ref).first).to eq(:"ref/a_1")
  ensure
    session&.close
  end

  it 'gives tracked audio markers from its times, and one section without changes' do
    audio = self.class.sections_audio([[:b, 8]], bpm: 240)
    r = MB::Sound::Structure.analyze(audio, bpm: 240, refine: false)
    expect(r.sections.length).to eq(1)
    expect(r.sections[0].bars).to be >= 7
    session = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2), transport: self.class.grid(240))
    m = r.markers!(session: session)
    expect(m.length).to eq(1)
    expect(m[0].pos.to_f).to be_within(1e-3).of(r.sections[0].seconds * 240 / 240.0)
  ensure
    session&.close
  end

  describe 'on a rendered flow (self-check against take.form)' do
    def self.song
      s = MB::Sound
      n = ->(x) { MB::Sound.const_get(x) }
      pad_a = s.seq([n.(:A3), n.(:C4), n.(:E4)], [n.(:F3), n.(:A3), n.(:C4)]).n1.loop
      pad_c = s.seq([n.(:F3), n.(:A3), n.(:C4)], [n.(:G3), n.(:B3), n.(:D4)]).n1.loop
      bass_v = s.seq(n.(:A1), n.(:A1), n.(:C2), n.(:A1), n.(:F1), n.(:F1), n.(:G1), n.(:E1)).n4.loop
      bass_c = s.seq(n.(:F1), n.(:F2), n.(:G1), n.(:G2)).n2.loop
      lead = s.seq(n.(:E5), n.(:D5), n.(:C5), n.(:D5), n.(:E5), n.(:G5), n.(:A5), n.(:G5)).n8.loop
      beat_v = s.grid(16, kick: 'X...X...X...X...', clap: '....X.......X...', closed_hat: '..x...x...x...x.').loop
      beat_c = s.grid(16, kick: 'X...X...X...X...', clap: '....X.......X...', closed_hat: 'xxxxxxxxxxxxxxxx', open_hat: '..x...x...x...x.').loop
      s.track(:drums) { |kit| s.tr808(kit) }
      s.track(:bass) { |c| v = c.notes; v.hz.saw.lp4(500) * v.amp_env(0.005, 0.2, 0.7, 0.05) * 0.4 }
      s.track(:pad) { |c| c.synth(voices: 3) { |v, _| v.hz.saw * v.amp_env(0.2, 0.5, 0.8, 0.5) * 0.12 } }
      s.track(:lead) { |c| v = c.notes; v.hz.square.lp4(3000) * v.amp_env(0.01, 0.1, 0.6, 0.1) * 0.15 }
      s.scene :intro, pad: pad_a
      s.scene :verse, drums: beat_v, bass: bass_v, pad: pad_a
      s.scene :chorus, drums: beat_c, bass: bass_c, pad: pad_c, lead: lead
      s.scene :outro, pad: pad_a
      s.flow do
        intro 8
        verse 8
        chorus 8
        verse
        outro 8
      end
    end

    it 'finds the flow it played' do
      MB::Sound.seed(1)
      take = nil
      r = MB::Sound.analyze_form(bars: 40, bpm: 240) {
        take = MB::Sound::Take.new(session: MB::Sound::Session.current)
        self.class.song
      }
      expect(take.form.to_ruby).to eq("flow do\n  intro 8\n  verse 8\n  chorus 8\n  verse\n  outro 8\nend")
      c = r.compare(take.form)
      expect(c.f).to eq(1.0), c.to_s
      expect(c).to be_exact
      # The intro and outro play the same pad (one label), the verses the
      # same parts; the chorus adds to the verse's drums and bass (a new
      # label or a variant)
      l = r.labels
      expect(l.length).to eq(5)
      expect(l[0]).to eq(l[4])
      expect(l[1]).to eq(l[3])
      expect(l.values_at(0, 1, 2).uniq.length).to eq(3)
      expect(c.label_recall).to eq(1.0)
    end
  end
end
