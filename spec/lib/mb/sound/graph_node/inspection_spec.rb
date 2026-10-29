# The inspection protocol (racks R1, design/notes/racks.md): generic
# #params/#param_info, #plot_preview, snapshot spies, and MIDI::Stream#spy
# with Session stamps.
RSpec.describe('GraphNode inspection protocol') do
  let(:c4) { MB::Sound::C4 }
  let(:e4) { MB::Sound::E4 }

  describe '#params' do
    it 'lists a filter node\'s parameters, constants as numbers' do
      f = 110.hz.saw.filter(:lowpass, cutoff: 800, quality: 4)
      expect(f.params).to eq(cutoff: 800, quality: 4)
      expect(f.param_info[:cutoff].to_h).to include(value: 800, type: :control, unit: 'Hz')
    end

    it 'gives nodes as they are, typed' do
      lfo = 3.hz.lfo.at(200..900)
      f = 110.hz.saw.filter(:lowpass, cutoff: lfo)
      expect(f.params[:cutoff]).to be_a(MB::Sound::GraphNode)
      expect(f.param_info[:cutoff].to_h).to include(value: nil, type: :control, detail: MB::Sound::GraphNode::Traversable.words_of(lfo))
    end

    it 'describes knob readers with their range' do
      k = MB::Sound::GraphNode::Knob.new(:cut, 800, range: 100..8000)
      f = 110.hz.saw.filter(:lowpass, cutoff: k)
      info = f.param_info[:cutoff].to_h
      expect(info).to include(value: 800, range: 100..8000, label: :cut)
    end

    it 'leaves main inputs out' do
      expect(110.hz.saw.softclip.params).to eq({})
    end

    it 'keeps ChannelMixer#params and adds declared ranges' do
      w = MB::Sound.stereo(110.hz.saw, 220.hz.saw).width(0.5)
      mixer = w.to_a[0].original_source rescue w.to_a[0].sources[:mixer]
      expect(mixer.params).to include(amount: 0.5)
      expect(mixer.param_info[:amount].value).to eq(0.5)
    end
  end

  describe '#param_snapshot' do
    it 'is one deep-frozen value a poll thread can take' do
      k = MB::Sound::GraphNode::Knob.new(:cut, 800, range: 100..8000)
      f = 110.hz.saw.filter(:lowpass, cutoff: k, quality: 2).named('lp')
      snap = f.param_snapshot
      expect(Ractor.shareable?(snap)).to eq(true)
      expect(snap.node_class).to eq(MB::Sound::Filter::SampleWrapper)
      expect(snap.name).to eq('lp')
      expect(snap[:cutoff]).to eq(800)
      expect(snap[:quality]).to eq(2)
      expect(snap.preview).to include(structure: :svf, filter_type: :lowpass, cutoff: 800.0, quality: 2.0, sample_rate: 48000.0)
    end

    it 'gives nil preview data for nodes without previews' do
      expect(110.hz.saw.param_snapshot.preview).to be_nil
    end
  end

  describe '#plot_preview' do
    it 'is a pure function of the snapshot (Plot::Panels.preview)' do
      c = 800.constant
      f = 110.hz.saw.filter(:lowpass, cutoff: c, quality: 4)
      snap = f.param_snapshot
      c.constant = 3000
      chart = MB::Sound::Plot::Panels.preview(f.class, snap, MB::Sound::Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: :auto, grid: true))
      line = chart.build.marks.find { |m| m.is_a?(MB::Sound::Plot::Mark::Line) }
      expect(line.label).to include('800.0 Hz')
      expect(MB::Sound::Plot::Panels.registered).to include('MB::Sound::Filter::SampleWrapper', 'MB::Sound::GraphNode::Shaper')
    end

    it 'is nil by default' do
      expect(MB::Sound::Plot.preview(110.hz.saw)).to be_nil
      expect(110.hz.saw.plot_preview(nil)).to be_nil
    end

    it 'draws a filter response at the constant settings' do
      lp = MB::Sound::Plot.preview(110.hz.saw.filter(:lowpass, cutoff: 800, quality: 4))
      expect(lp).to be_a(MB::Sound::Plot::Chart)
      line = lp.marks.find { |m| m.is_a?(MB::Sound::Plot::Mark::Line) }
      expect(line).not_to be_nil
      expect(lp.to_s).to be_a(String)

      f, db = MB::Sound::Plot::Presets.response_db(MB::Sound::Filter::SVF.new(:lowpass, 48000, 800, quality: 4), 48000)
      peak = f[db.max_index]
      expect(peak).to be_within(60).of(800)
      expect(db.max).to be_within(1).of(20 * Math.log10(4))
    end

    # sound-design-nav-1: the FILTER section's main view
    it 'draws lp4 and diode responses with their resonance and tuning' do
      # (the drawn line's dB at +hz+, between its points in log frequency)
      at = ->(chart, hz) {
        line = chart.marks.select { |m| m.is_a?(MB::Sound::Plot::Mark::Line) }.last
        x = line.x.to_a
        i = (x.bsearch_index { |v| v >= hz } || x.length - 1).clamp(1, x.length - 1)
        t = (Math.log(hz) - Math.log(x[i - 1])) / (Math.log(x[i]) - Math.log(x[i - 1]))
        line.y[i - 1] + (line.y[i] - line.y[i - 1]) * t
      }
      flat = MB::Sound::Plot.preview(110.hz.saw.lp4(1000.hz))
      expect(flat.title).to eq('lp4 1000 Hz reso 0')
      expect(at.(flat, 1000)).to be_within(0.5).of(-6) # (musical tuning: -6 dB at the cutoff)
      peak = MB::Sound::Plot.preview(110.hz.saw.lp4(1000.hz, resonance: 0.6))
      line = peak.marks.select { |m| m.is_a?(MB::Sound::Plot::Mark::Line) }.last
      expect(line.x[line.y.max_index]).to be_within(100).of(1000) # (the peak on the cutoff)
      expect(line.y.max).to be > 6
      hw = MB::Sound::Plot.preview(110.hz.saw.lp4(1000.hz, tuning: :hardware))
      expect(hw.title).to eq('lp4 1000 Hz reso 0 hardware')
      expect(at.(hw, 1000)).to be < -9
      expect(MB::Sound::Plot.preview(110.hz.saw.diode(1000.hz, resonance: 0.3)).title).to eq('diode 1000 Hz reso 0.3')
      diode = MB::Sound::Plot.preview(110.hz.saw.diode(1000.hz))
      expect(at.(diode, 8000)).to be > at.(flat, 8000) + 20 # (a gentler slope)

      # The drawn response is the kernel's: an impulse through the filter at the same settings
      [[:lp4, 0.0, :musical], [:lp4, 0.6, :hardware], [:diode, 0.3, :musical], [:diode, 0.6, :hardware]].each do |mode, res, tuning|
        chart = MB::Sound::Plot.preview(110.hz.saw.lp4(1000.hz, resonance: res, mode: mode, tuning: tuning))
        f = MB::Sound::Filter::FourPole.new(cutoff: 1000, resonance: res, mode: mode, tuning: tuning, sample_rate: 48000)
        imp = Numo::SFloat.zeros(16384)
        imp[0] = 1e-3
        spec = Numo::Pocketfft.rfft(Numo::DFloat.cast(f.process(imp)) / 1e-3).abs
        [250, 1000, 3000].each do |hz|
          bin = (hz * 16384 / 48000.0).round
          expect(at.(chart, bin * 48000 / 16384.0)).to be_within(0.5).of(20 * Math.log10(spec[bin])), "#{mode} #{res} #{tuning} at #{hz} Hz"
        end
      end

      # A moving cutoff: where it was last read, an octave either side dashed, ~ in the title
      moving = 110.hz.saw.lp4(0.5.hz.lfo.at(500..2000), resonance: 0.2)
      moving.sample(800)
      chart = MB::Sound::Plot.preview(moving)
      expect(chart.title).to match(/\Alp4 ~\d+ Hz reso 0.2\z/)
      expect(chart.marks.count { |m| m.is_a?(MB::Sound::Plot::Mark::Line) }).to eq(3)
      expect(moving.preview_data[:moving]).to eq([:cutoff])
    end

    it 'draws a shaper transfer curve' do
      c = MB::Sound::Plot.preview(110.hz.saw.softclip)
      expect(c).to be_a(MB::Sound::Plot::Chart)
      expect(c.marks.length).to eq(2)
    end
  end

  describe 'spy(snapshot: true)' do
    it 'hands each buffer frozen and kept' do
      got = []
      t = 110.hz.saw.spy(snapshot: true) { |b| got << b }
      bufs = 3.times.map { t.sample(10).dup }
      expect(got.length).to eq(3)
      expect(got).to all(be_frozen)
      expect(got.map(&:__id__).uniq.length).to eq(3)
      expect(got).to eq(bufs)
    end

    it 'shares one copy among snapshot spies of a node' do
      a = []
      b = []
      t = 110.hz.saw.spy(snapshot: true) { |x| a << x }.spy(snapshot: true) { |x| b << x }
      t.sample(10)
      expect(a[0]).to equal(b[0])
    end

    it 'works for nodes fused into a plan (Op::Tap)' do
      old = MB::Sound::Plan.enabled
      MB::Sound::Plan.enabled = true
      got = []
      inner = 110.hz.saw.filter(:lowpass, cutoff: 800)
      inner.spy(snapshot: true) { |x| got << x }
      out = inner * 0.5
      MB::Sound::Plan.install(out)
      ref = []
      4.times { out.sample(64) }
      expect(got.length).to eq(4)
      expect(got).to all(be_frozen)
      expect(got.map(&:length).uniq).to eq([64])
      expect(ref).to eq([])
    ensure
      MB::Sound::Plan.enabled = old
    end
  end

  describe 'MIDI::Stream#spy' do
    it 'yields each event once, with nil stamps outside a Session' do
      st = MB::Sound.seq(c4, e4).n8.loop.stream
      seen = []
      st.spy { |e, at| seen << [e.type, e.time, at] }
      r1 = st.reader
      r2 = st.reader
      r1.next(0.5r)
      r2.next(0.5r)
      expect(seen.map(&:first)).to eq([:note_on, :note_off, :note_on]) # [0, 0.5): the second note-off is at 0.5 s
      expect(seen.map(&:last).uniq).to eq([nil])
    end

    it 'stamps events with the Session frame and position they land on' do
      sess = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2, sample_rate: 48000, sleep: false))
      seen = []
      clip = MB::Sound.seq(c4, e4).n8.loop
      syn = clip.stream.spy { |e, at| seen << [e.type, at.frame, at.to_s] }.synth { |v| v.hz.saw * v.amp_env }
      sess.add(syn, name: :x)
      40.times { sess.process_buffer }
      expect(seen.first(4)).to eq([[:note_on, 0, '1:1'], [:note_off, 12000, '1:1.5'], [:note_on, 12000, '1:1.5'], [:note_off, 24000, '1:2']])
    ensure
      sess&.close
      MB::Sound.rewind
    end

    it 'removes spies by handle' do
      st = MB::Sound.seq(c4).n8.loop.stream
      seen = []
      st.spy(handle: :a) { |e, _| seen << e }
      st.clear_spies(handle: :a)
      st.reader.next(1r)
      expect(seen).to be_empty
    end
  end
end
