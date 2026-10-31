# Reference mastering (master :match): Analysis::Spectrum's tilt, the tilt
# EQ, Mastering.reference, the :match preset, and renders reaching a
# reference's loudness and tilt.
RSpec.describe('MB::Sound::Mastering :match', :aggregate_failures) do
  rate = 48000

  # Rendered audio of +graph+ for +seconds+ (channels).
  def rendered(graph, seconds)
    cap = MB::Sound::Structure::Capture.new
    MB::Sound.render(cap, graph, seconds: seconds, gain: 1)
    cap.data
  end

  describe MB::Sound::Analysis::Spectrum do
    it 'measures white noise at +3 dB/oct and pink noise near 0, gating silence' do
      white = Numo::DFloat.new(rate * 4).rand_norm * 0.1
      expect(MB::Sound::Analysis::Spectrum.new(white).tilt).to be_within(0.1).of(3)
      pink = rendered(MB::Sound.noise(:pink), 4)
      sp = MB::Sound::Analysis::Spectrum.new(pink)
      expect(sp.tilt).to be_within(0.15).of(0)
      expect(sp.bands.keys).to include(100.0, 1000.0, 10000.0)
      expect(sp.inspect).to match(/tilt [-+]0\.\d\d dB\/oct/)

      gated = MB::Sound::Analysis::Spectrum.new(Numo::DFloat.hstack([white, Numo::DFloat.zeros(rate * 4)]))
      expect(gated.tilt).to be_within(0.05).of(MB::Sound::Analysis::Spectrum.new(white).tilt)
      expect(gated.frames).to be < gated.total_frames
      expect(MB::Sound::Analysis::Spectrum.new(Numo::DFloat.zeros(rate)).tilt).to eq(0.0)
    end
  end

  describe 'Mastering.tilt_eq' do
    it 'tilts by its slope around 1 kHz' do
      white = Numo::SFloat.new(rate * 4).rand_norm * 0.05
      [1.0, -1.5].each do |s|
        node = MB::Sound::Mastering.tilt_eq(MB::Sound::ArrayInput.new(data: [white]), s)
        out = node.sample(white.size)
        expect(MB::Sound::Analysis::Spectrum.new(out).tilt).to be_within(0.15).of(3 + s)
      end
      sine = Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(rate).seq * 2 * Math::PI * 1000 / rate) * 0.5)
      out = MB::Sound::Mastering.tilt_eq(MB::Sound::ArrayInput.new(data: [sine]), 1.2).sample(rate)
      expect(20 * Math.log10(out[rate / 2..].abs.max / 0.5)).to be_within(0.05).of(0)
      src = MB::Sound::ArrayInput.new(data: [sine])
      expect(MB::Sound::Mastering.tilt_eq(src, 0)).to equal(src)
    end
  end

  describe 'Mastering.reference' do
    it 'measures a file once, a Sample, and audio' do
      path = tmp_path('ref.flac')
      MB::Sound.write(path, rendered(MB::Sound.noise(:pink) * 0.5, 3))
      ref = MB::Sound::Mastering.reference(path)
      expect(ref.name).to eq('ref.flac')
      expect(ref.path).to eq(path)
      expect(ref.lufs).to be_within(1).of(-17)
      expect(ref.tilt).to be_within(0.2).of(0)
      expect(ref.seconds).to be_within(0.01).of(3)
      expect(MB::Sound::Mastering.reference(path)).to equal(ref)
      expect(ref.to_s).to match(/\Aref\.flac: -1\d\.\d LUFS, -?\d+\.\d dBTP, LRA \d+\.\d LU, tilt [-+]0\.\d\d dB\/oct\z/)

      s = MB::Sound::Sample[path]
      expect(MB::Sound::Mastering.reference(s).lufs).to be_within(0.01).of(ref.lufs)
      expect(MB::Sound::Mastering.reference(s)).to equal(MB::Sound::Mastering.reference(s))
      expect(MB::Sound::Mastering.reference(MB::Sound.read(path), name: 'x').name).to eq('x')
      expect(MB::Sound::Mastering.reference(ref)).to equal(ref)
      expect { MB::Sound::Mastering.reference(:nope) }.to raise_error(ArgumentError, /reference: is a sound file/)
      expect { MB::Sound::Mastering.reference([Numo::SFloat.zeros(rate)]) }.to raise_error(ArgumentError, /silent/)
    end
  end

  # measure: :integrated | :loudest | :histogram (maintainer, 2026-10-31:
  # "Histogram, loudest, and integrated all as options")
  describe 'measures' do
    # 8 s of pink noise at 0.5, then 8 s at 0.25 (6 dB quieter, over the
    # relative gate, so the integrated loudness reads both)
    def loud_then_quiet
      @loud_then_quiet ||= rendered((MB::Sound.noise(:pink) * 0.5).until(8).and_then(MB::Sound.noise(:pink) * 0.25), 16)
    end

    it 'read the reference whole, by its loudest window, or by the center of its bar histogram' do
      MB::Sound.seed(3)
      ref = MB::Sound::Mastering.reference(loud_then_quiet)
      loud = MB::Sound::Mastering.reference(loud_then_quiet.map { |c| c[0...(rate * 8)] })
      quiet = MB::Sound::Mastering.reference(loud_then_quiet.map { |c| c[(rate * 8)..] })
      level = ->(m, **kw) { MB::Sound::Mastering.reference_level(ref, m, bar_seconds: 2.0, **kw) }

      expect(level.(:integrated)).to eq(ref.lufs)
      expect(level.(:loudest, bars: 2)).to be_within(0.2).of(loud.lufs)
      expect(level.(:loudest, bars: 2, seconds: 1.0)).to be > level.(:loudest, bars: 2) - 0.5
      # Four bars of each: the quantiles from 10 to 90% average to the
      # middle of the two levels
      expect(level.(:histogram)).to be_within(0.3).of((loud.lufs + quiet.lufs) / 2)
      expect(quiet.lufs).to be < loud.lufs - 5
      expect(ref.lufs).to be < loud.lufs - 1
      # A track shorter than the window is measured whole
      expect(level.(:loudest, bars: 16)).to be_within(0.01).of(ref.lufs)
      expect(MB::Sound::Mastering.bar_ranges(16.0, 2.0).length).to eq(8)
      expect(MB::Sound::Mastering.bar_ranges(1.5, 2.0)).to eq([[0.0, 1.5]])

      expect { MB::Sound::Mastering.reference_level(ref.with(analyzer: nil), :histogram, bar_seconds: 2.0) }.to raise_error(ArgumentError, /no loudness blocks/)
      expect { level.(:bars) }.to raise_error(ArgumentError, /measure: is :integrated, :loudest, :histogram for :match/)
    end

    it 'find the histogram center from interpolated quantiles, leaving out silence and bars 20 LU under the loudest' do
      levels = [-10.0, -12.0, -14.0, -16.0, -18.0, nil, -Float::INFINITY, -45.0]
      expect(MB::Sound::Mastering.histogram_quantiles(levels, [0.0, 0.5, 0.75, 1.0])).to eq([-18.0, -14.0, -12.0, -10.0])
      expect(MB::Sound::Mastering.histogram_level(levels)).to be_within(1e-9).of(-14.0)
      expect(MB::Sound::Mastering.histogram_level([nil])).to be_nil
    end

    it "set the preset's target, accepting only measures a reference has, and raise for :histogram on other presets" do
      ref = MB::Sound::Mastering.reference(loud_then_quiet)
      MB::Sound::Sequence.transport.bpm = 120
      p = MB::Sound::Mastering.from_preset(:match, reference: ref, measure: :histogram)
      expect(p.target.lufs).to eq(MB::Sound::Mastering.reference_level(ref, :histogram, bar_seconds: 2.0))
      expect(p).to be_reference_target
      expect(p.summary).to start_with(format('match: %.1f LUFS (the bar-loudness histogram)', p.target.lufs))
      expect(MB::Sound::Mastering.from_preset(:match, reference: ref, measure: :loudest, loudest_bars: 2).target.lufs).to be > ref.lufs + 1
      fixed = MB::Sound::Mastering.from_preset(:match, reference: ref, measure: :loudest, lufs: -12)
      expect([fixed.target.lufs, fixed.reference_target?]).to eq([-12.0, false])

      expect { MB::Sound::Mastering.from_preset(:match, reference: ref, measure: :bars) }.to raise_error(ArgumentError, /measures :integrated, :loudest, :histogram .*:histogram matches the bars' loudness/)
      expect { MB::Sound::Mastering.from_preset(:match, reference: ref, measure: :histo) }.to raise_error(ArgumentError, /Did you mean\?  :histogram/)
      expect { MB::Sound::Mastering.from_preset(:match, reference: ref, measure: :histogram, percentile: 0.5) }.to raise_error(ArgumentError, /percentile: goes with measure: :bars/)
      expect { MB::Sound::Mastering.from_preset(:club, measure: :histogram) }.to raise_error(ArgumentError, /:histogram matches a reference's bar-loudness histogram: master :match/)
      expect { MB::Sound::Mastering.from_preset(:club, measure: :loudst) }.to raise_error(ArgumentError, /Did you mean\?  :loudest/)
    ensure
      MB::Sound::Sequence.transport.bpm = 120
    end

    it "reach the reference's loudest window or histogram center in renders, with the render's bar length" do
      ref_path = tmp_path('loud_quiet.flac')
      MB::Sound.write(ref_path, loud_then_quiet)
      ref = MB::Sound::Mastering.reference(ref_path)
      # A mix with one quiet bar, then loud ones
      mix = -> { MB::Sound.seed(4); (MB::Sound.noise(:pink) * 0.05).until(2).and_then(MB::Sound.noise(:pink) * 0.2) }
      { loudest: { loudest_bars: 1 }, histogram: {} }.each do |m, kw|
        expect {
          MB::Sound.render(tmp_path("#{m}.flac"), seconds: 4) { MB::Sound.master :match, reference: ref_path, measure: m, **kw; MB::Sound.bg :x, mix.() }
        }.to output(/mastering :match: pass/).to_stdout
        r = MB::Sound::Mastering::Targeting.last
        expected = MB::Sound::Mastering.reference_level(ref, m, bar_seconds: 2.0, bars: 1)
        expect(r.reference_level).to eq(expected)
        expect(r.target.lufs).to eq(expected)
        expect(r.measure).to eq(m)
        expect(r.loudest).to be_within(0.1).of(expected)
        text = r.to_s
        if m == :histogram
          expect(text).to include(format('bar histogram center %.2f LUFS', r.loudest), format('bar histogram center %.1f, ', expected))
          expect(text).to match(%r{bar loudness 10/50/90%: reference -\d+\.\d / -\d+\.\d / -\d+\.\d, mastered })
          expect(r.histogram[:reference]).to eq(MB::Sound::Mastering.histogram_quantiles(ref.analyzer.loudness_in(MB::Sound::Mastering.bar_ranges(ref.seconds, 2.0))))
        else
          expect(text).to include(format('loudest 1 bars %.1f, ', expected))
          expect(r.histogram).to be_nil
        end
      end
    end
  end

  describe 'the :match preset' do
    let(:ref) {
      MB::Sound::Mastering::Reference.new(name: 'ref', path: 'ref.flac', lufs: -9.3, true_peak: 0.4, short_term_max: -8, range: 4,
        tilt: -0.8, bands: {}, seconds: 30)
    }

    it "takes the reference's loudness and true peak, within limits" do
      p = MB::Sound::Mastering.from_preset(:match, reference: ref)
      expect(p.target.lufs).to eq(-9.3)
      expect(p.ceiling.db_value).to eq(-0.5) # (+0.4 dBTP, within -3..-0.5)
      expect(p.reference).to equal(ref)
      expect(p.steps.map(&:first)).to eq(%i[trim tilt compress limit limit])
      expect(p).to be_measured_tilt
      expect(p.fixed_tilt).to be_nil
      expect(p.summary).to eq('match: -9.3 LUFS, -0.5 dBTP, like ref (tilt -0.80 dB/oct); trim -> tilt -> compress -> limit -> limit')
      expect(p.call_ruby).to eq(':match, reference: "ref.flac"')

      quiet = ref.with(lufs: -23.0, true_peak: -12.0)
      expect(MB::Sound::Mastering.from_preset(:match, reference: quiet).ceiling.db_value).to eq(-3.0)
      p = MB::Sound::Mastering.from_preset(:match, reference: ref, lufs: -12, ceiling: -1.db, tilt: 0.5)
      expect([p.target.lufs, p.ceiling.db_value, p.fixed_tilt]).to eq([-12.0, -1.0, 0.5])
      expect(p).not_to be_measured_tilt
      expect(MB::Sound::Mastering.from_preset(:match, reference: ref, tilt: false).steps.map(&:first)).not_to include(:tilt)
      expect(MB::Sound::Mastering.from_preset(:match, reference: ref, drive: 6.db)).not_to be_measured_tilt
      expect(MB::Sound::Mastering.names).to include(:match)
    end

    it 'raises without a reference and for options other presets would ignore' do
      expect { MB::Sound::Mastering.from_preset(:match) }.to raise_error(ArgumentError, /needs reference: the track to match/)
      expect { MB::Sound::Mastering.from_preset(:club, reference: ref) }.to raise_error(ArgumentError, /would ignore reference: \(an option of :match\)/)
      expect { MB::Sound::Mastering.from_preset(:match, reference: ref, tilt: :yes) }.to raise_error(ArgumentError, /tilt: is true/)
      expect { MB::Sound::Mastering.from_preset(:match, reference: ref, clip: true) }.to raise_error(ArgumentError, /would ignore clip:/)
    end

    it 'prints references that are not files as FIXMEs' do
      p = MB::Sound::Mastering.from_preset(:match, reference: ref.with(path: nil))
      expect(MB::Sound::Mastering.ruby(p.reference)).to start_with('nil # FIXME(graph-io)')
      expect(MB::Sound::Mastering.ruby([Numo::SFloat.zeros(3)])).to start_with('nil # FIXME(graph-io)')
    end
  end

  describe 'renders' do
    # A bright reference (white over pink, tilt about +1.1) and a dark,
    # quiet mix (brown noise and a sine, tilt about -3.9)
    def reference_file
      path = tmp_path('bright_ref.flac')
      MB::Sound.render(path, (MB::Sound.noise * 0.3 + MB::Sound.noise(:pink) * 0.8) * 0.5, seconds: 3, gain: 1)
      path
    end

    def dark_mix
      MB::Sound.noise(:brown) * 0.3 + 220.hz.at(0.1)
    end

    it "reach the reference's loudness and turn toward its tilt (within MAX_TILT)" do
      ref_path = reference_file
      ref = MB::Sound::Mastering.reference(ref_path)
      out = tmp_path('out.flac')
      expect {
        MB::Sound.render(out, seconds: 3) { MB::Sound.master :match, reference: ref_path; MB::Sound.bg :x, dark_mix }
      }.to output(/mastering :match: pass .*\n.*\n.*\n  like bright_ref\.flac .*tilt: reference \+1\.\d\d dB\/oct, mix -3\.\d\d, EQ \+1\.50, mastered -2\.\d\d/).to_stdout
      r = MB::Sound::Mastering::Targeting.last
      expect(r.integrated).to be_within(0.05).of(ref.lufs)
      expect(r.tilt).to eq(MB::Sound::Mastering::MAX_TILT)
      expect(r.tilt_out).to be_within(0.3).of(r.tilt_in + r.tilt)
      written = MB::Sound::Mastering.reference(MB::Sound.read(out))
      expect(written.lufs).to be_within(0.05).of(ref.lufs)
      expect(written.tilt).to be_within(0.05).of(r.tilt_out)
      expect(written.true_peak).to be <= -0.4
    end

    it 'correct a smaller tilt difference exactly, the same at any buffer size' do
      ref_path = tmp_path('pinkish.flac')
      MB::Sound.render(ref_path, MB::Sound.noise(:pink) * 0.5, seconds: 3, gain: 1)
      mix = -> { (MB::Sound.noise(:pink) * 0.4).filter(:highshelf, cutoff: 2000, quality: 0.7071, gain: -3.db) }
      files = slow_tier([800, 333], keep: 1).map { |size|
        out = tmp_path("pinkish_#{size}.flac")
        MB::Sound.seed(5)
        MB::Sound::Internal.without_stdout {
          MB::Sound.render(out, seconds: 3, buffer_size: size) { MB::Sound.master :match, reference: ref_path; MB::Sound.bg :x, mix.() }
        }
        r = MB::Sound::Mastering::Targeting.last
        expect(r.tilt.abs).to be < MB::Sound::Mastering::MAX_TILT
        expect(r.tilt_out).to be_within(0.15).of(MB::Sound::Mastering.reference(ref_path).tilt)
        MB::Sound.read(out)
      }
      expect(files.map { |f| f[0].to_a }.uniq.length).to eq(1) if files.length > 1
    end

    it 'master live without a measured tilt (tilt: a number for one)' do
      ref = MB::Sound::Mastering::Reference.new(name: 'ref', path: nil, lufs: -14.0, true_peak: -1.0, short_term_max: -12, range: 4,
        tilt: 0.0, bands: {}, seconds: 30)
      shelves = ->(preset) {
        out = preset.apply(MB::Sound::GraphNode::Channels.new([0.constant, 0.constant]))
        out.outputs[0].graph.count { |n| n.is_a?(MB::Sound::Filter::SampleWrapper) }
      }
      expect(shelves.(MB::Sound::Mastering.from_preset(:match, reference: ref))).to eq(shelves.(MB::Sound::Mastering.from_preset(:match, reference: ref, tilt: false)))
      expect(shelves.(MB::Sound::Mastering.from_preset(:match, reference: ref, tilt: 0.5))).to be > shelves.(MB::Sound::Mastering.from_preset(:match, reference: ref, tilt: false))

      s = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), channels: 2,
        buffer_size: 800, realtime: false, raise_errors: true, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      s.add([110.hz.saw.at(0.1), 110.hz.saw.at(0.1)])
      s.master(:match, reference: ref)
      3.times { s.process_buffer }
      expect(s.master_info).to start_with('master: :match')
    ensure
      s&.close
    end
  end
end
