# A fitted voice as a knob patch (hand-tune-1): the fit's printed code and
# params become a graph document whose params are the track's knobs.
# Synthetic fits only (the maintainer's samples stay private).
RSpec.describe(MB::Sound::FitPatch, :aggregate_failures) do
  M = MB::Sound unless defined?(M)

  LEAD_CODE = 'synth(CLIP, voices: 1) { |v| (v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) * 4).softclip(0.3, 1.0) }'.freeze
  LEAD_PARAMS = {
    cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25), attack: [(0.001..1.0).at(0.01), 'Amp attack in seconds'],
    clip: (0.1..1.0).at(0.3),
  }.freeze
  # The same voice as Ruby, for comparing samples.
  LEAD_BLOCK = ->(c) { M.synth(c, voices: 1) { |v| (v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) * 4).softclip(0.3, 1.0) } }

  # A kit voice as the 909 study prints its structure fits (values to 6
  # places, 3 over 100).
  KICK_CODE = "kit(grid(16, kick: 'X...'), seed: 1) { voice(:kick) { |h| body = h.body(51.328155, decay: 0.468972, sweep: 2.061796); " \
              'h.mix(body.softclip(0.205115, 1.0), h.noise(decay: 0.035986, highpass: 482.059) * 0.562526) } }'.freeze

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  def run(setup, buffers: 40, acts: {})
    M.rewind
    M.seed(1)
    out = M::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = M::Session.new(output: out, realtime: false)
    @sessions << s
    M::Session.with_context(session: s) { setup.call(s) }
    buffers.times do |i|
      (a = acts[i]) && M::Session.with_context(session: s) { a.call(s) }
      s.process_buffer
    end
    [s, Numo::DFloat.cast(out.captured[0])]
  end

  describe '.document' do
    it 'names each fitted literal by its param and plays the clip through midi' do
      params = MB::Sound::FitPatch.declare(LEAD_PARAMS)
      text, sites, missing = MB::Sound::FitPatch.document(LEAD_CODE, params, name: :lead_fit)
      expect(missing).to eq([])
      expect(sites.map(&:name)).to eq(%i[cutoff resonance attack clip])
      expect(sites.first).to have_attributes(line: 1, text: '1234.5')
      expect(text).to include('synth(midi, voices: 1) { |v| (v.hz.saw.lp4(cutoff, resonance: resonance) * v.amp_env(attack, 0.2, 0.5, 0.1) * 4).softclip(clip, 1.0) }')
      expect(text).to include('param :cutoff, (100.0..8000.0).at(1234.5)')
      expect(text).to include('param :attack, (0.001..1.0).at(0.01), description: "Amp attack in seconds"')
      expect(text).to include('inputs midi: :notes')
      doc = MB::Sound::GraphIO.parse(text)
      expect(doc.params.keys).to eq(%i[cutoff resonance attack clip])
    end

    it 'matches rounded literals at their precision, preferring the keyword of the same name' do
      params = MB::Sound::FitPatch.declare(tune: (30.0..110.0).at(51.3281552816498), decay: (0.1..2.0).at(0.4689717265405018),
                                           sweep: (0.0..10.0).at(2.061796096559119), clip: (0.2..1.0).at(0.20511453002929883),
                                           tick_hp: (200.0..6000.0).at(482.0592639759637), tick: (0.0..1.5).at(0.5625264704140474),
                                           tick_decay: (0.001..0.04).at(0.035986406236405345))
      text, sites, missing = MB::Sound::FitPatch.document(KICK_CODE, params, name: :kick_fit)
      expect(missing).to eq([])
      expect(sites.length).to eq(7)
      expect(text).to include('kit(midi, seed: 1) { voice(:kick) { |h| body = h.body(tune, decay: decay, sweep: sweep); ' \
                              'h.mix(body.softclip(clip, 1.0), h.noise(decay: tick_decay, highpass: tick_hp) * tick) } }')
    end

    it 'lists params it finds nowhere and leaves short literals alone' do
      params = MB::Sound::FitPatch.declare(cutoff: (100.0..8000.0).at(1234.5), drive: (0.0..4.0).at(0.25001))
      text, sites, missing = MB::Sound::FitPatch.document(LEAD_CODE, params, name: :x)
      expect(missing).to eq([:drive])
      expect(sites.map(&:name)).to eq([:cutoff])
      expect(text).not_to include('param :drive')
      expect(text).to include('resonance: 0.25')
    end

    it 'refuses ambiguous literals, names the code assigns, and code without a voice' do
      both = MB::Sound::FitPatch.declare(a: (0.0..1.0).at(0.25), b: (0.0..1.0).at(0.25))
      expect { MB::Sound::FitPatch.document(LEAD_CODE, both, name: :x) }.to raise_error(MB::Sound::FitPatch::Error, /0\.25 at 1:\d+ matches :a and :b/)
      body = MB::Sound::FitPatch.declare(body: (0.0..1.0).at(0.5))
      expect { MB::Sound::FitPatch.document(KICK_CODE, body, name: :x) }.to raise_error(MB::Sound::FitPatch::Error, /assigns body itself/)
      expect { MB::Sound::FitPatch.document('220.hz.saw * 0.5', MB::Sound::FitPatch.declare(g: (0.0..1.0).at(0.5)), name: :x) }
        .to raise_error(MB::Sound::FitPatch::Error, /no voice played from a clip/)
      expect { MB::Sound::FitPatch.declare(cutoff: 1234.5) }.to raise_error(MB::Sound::FitPatch::Error, /\(lo\.\.hi\)\.at\(value\)/)
      expect { MB::Sound::FitPatch.declare(cutoff: (100.0..800.0).at(1234.5)) }.to raise_error(ArgumentError)
    end
  end

  describe '.save' do
    it 'writes a document to FitPatch.dir that loads, and an entry for tracks' do
      fit = MB::Sound::FitPatch.save(:lead_fit, LEAD_CODE, LEAD_PARAMS)
      expect(fit.path).to eq(File.join(MB::Sound::FitPatch.dir, 'lead_fit.mbg.rb'))
      expect(File.read(fit.path)).to eq(fit.text)
      expect(fit.entry).to have_attributes(name: :lead_fit, family: :preset, location: fit.path)
      expect(fit.values).to eq(cutoff: 1234.5, resonance: 0.25, attack: 0.01, clip: 0.3)
      expect(fit.to_s).to match(/fit patch lead_fit: 4 knobs \(cutoff, resonance, attack, clip\)/)
    end

    it 'says why a document does not load, keeping its text' do
      expect { MB::Sound::FitPatch.save(:bad, 'synth(CLIP) { |v| v.hz.saw.no_such_thing(0.5) }', { g: (0.0..1.0).at(0.5) }) }
        .to raise_error(MB::Sound::FitPatch::Error) { |e|
          expect(e.message).to match(/doesn't load or play/)
          expect(e.document).to include('no_such_thing(g)')
        }
    end
  end

  describe 'on a track' do
    let(:clip) { M.seq(M::A2, M::C3).n4.loop }

    it 'plays the fitted code bit for bit, every param a bounded knob of the track' do
      fit = MB::Sound::FitPatch.save(:lead_fit, LEAD_CODE, LEAD_PARAMS)
      _, want = run(->(_s) { M.track(:lead) { |c| LEAD_BLOCK.(c) }; M.bg(:lead, clip) })
      s, got = run(->(_s) { M.track(:lead, fit); M.bg(:lead, clip) })
      expect(want.abs.max).to be > 0.2 # (0.82 before the master's -10 dB: the softclip shapes it)
      expect(got).to eq(want)
      expect(s.knobs.keys).to include(:"lead/cutoff", :"lead/resonance", :"lead/attack", :"lead/clip")
      expect(s.knobs[:"lead/cutoff"].spec.range).to eq(100.0..8000.0)
      expect(s.knobs[:"lead/cutoff"].value).to eq(1234.5)
    end

    it 'turns live knobs live and makes a clip threshold a build knob' do
      fit = MB::Sound::FitPatch.save(:lead_fit, LEAD_CODE, LEAD_PARAMS)
      _, want = run(->(_s) { M.track(:lead, fit); M.bg(:lead, clip) })
      s, got = run(->(_s) { M.track(:lead, fit); M.bg(:lead, clip) }, acts: { 10 => ->(_s) { M.turn(:"lead/cutoff", 300.0, smooth: 0) } })
      expect(got[0...8000]).to eq(want[0...8000])
      expect((got[9000..] - want[9000..]).abs.max).to be > 0.05
      expect(s.arrangement.build_knob?(:"lead/clip")).to eq(true)
      expect(s.arrangement.build_knob?(:"lead/cutoff")).to eq(false)
    end

    it 'plays a fitted kit voice from a clip' do
      params = { tune: (30.0..110.0).at(51.328155), decay: (0.1..2.0).at(0.468972), clip: (0.2..1.0).at(0.205115) }
      fit = MB::Sound::FitPatch.save(:kick_fit, KICK_CODE, params)
      s, got = run(->(_s) { M.track(:kick, fit); M.bg(:kick, M.seq(M::C2).n4.loop) })
      expect(got.abs.max).to be > 0.05
      expect(s.knobs[:"kick/tune"].value).to eq(51.328155)
    end
  end
end
