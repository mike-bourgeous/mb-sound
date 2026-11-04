# A fitted voice as a knob patch (hand-tune-1): the fit's printed code and
# params become a graph document whose params are the track's knobs.
# Synthetic fits only (the maintainer's samples stay private).
RSpec.describe(MB::Sound::FitPatch, :aggregate_failures) do
  LEAD_CODE = 'synth(CLIP, voices: 1) { |v| (v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) * 4).softclip(0.3, 1.0) }'.freeze
  LEAD_PARAMS = {
    cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25), attack: [(0.001..1.0).at(0.01), 'Amp attack in seconds'],
    clip: (0.1..1.0).at(0.3),
  }.freeze
  # The same voice as Ruby, for comparing samples.
  LEAD_BLOCK = ->(c) { MB::Sound.synth(c, voices: 1) { |v| (v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) * 4).softclip(0.3, 1.0) } }

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
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) { setup.call(s) }
    buffers.times do |i|
      (a = acts[i]) && MB::Sound::Session.with_context(session: s) { a.call(s) }
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

    it 'leaves literals a param cannot take as numbers, saying why, and unwraps a play line' do
      code = 'play (synth(seq(C4).len(1/8r), voices: 1) { |v| (v.hz.saw * v.env(0.0013, 0.0555, 0.4433, 0.05, sensitivity: 1.0..1.0)).then { |u| u + u * u * -0.5743 }' \
             '.filter(:peak, cutoff: 1605.4, quality: 3.7526, gain: 0.7968.db) })'
      params = MB::Sound::FitPatch.declare(att: (0.0001..1.0).at(0.00132698), dec: (0.001..5.0).at(0.0555094), sus: (0.0..1.0).at(1.0),
                                           sq: (-1.0..1.0).at(-0.57429), f: (100.0..8000.0).at(1605.43), g: (-12.0..12.0).at(0.79684))
      text, sites, missing, skipped = MB::Sound::FitPatch.document(code, params, name: :x)
      # (a then block runs once while building: its numbers are params,
      # fit-patch-2; runtime blocks are below)
      expect(sites.map(&:name)).to eq(%i[att dec sq f])
      expect(missing).to eq(%i[sus g])
      expect(skipped).to eq(sus: '1.0 is inside a Range (a setting, not a knob)', g: '0.7968 is a typed value (0.7968.db): bind it in the inspector')
      expect(text).to include('.then { |u| u + u * u * sq }')
      expect(text).to include('synth(midi, voices: 1) { |v| (v.hz.saw * v.env(att, dec, 0.4433, 0.05, sensitivity: 1.0..1.0))')
      expect(text).not_to include('play')
    end

    it 'gives a literal two params round to the closer one' do
      params = MB::Sound::FitPatch.declare(spacing: (0.004..0.02).at(0.0085), burst: (0.002..0.03).at(0.009))
      _, sites, = MB::Sound::FitPatch.document('synth(CLIP) { |v| v.hz.saw.lp4(0.0085 * 1e5) * v.env(0.009, 0.1, 0, 0.1) }', params, name: :x)
      expect(sites.map { |x| [x.name, x.text] }).to eq([['spacing', '0.0085'], ['burst', '0.009']].map { |n, t| [n.to_sym, t] })
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
      # (the track plays the version, an immutable copy; its lineage is the
      # path, where the document is edited: hand-tune-2)
      expect(fit.entry).to have_attributes(name: :lead_fit, family: :preset, location: fit.version)
      expect(fit.version).to match(%r{/versions/lead_fit-\h{12}\.mbg\.rb\z})
      expect(File.read(fit.version)).to eq(fit.text)
      expect(fit.entry.settings[:lineage]).to eq(fit.path)
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
    let(:clip) { MB::Sound.seq(MB::Sound::A2, MB::Sound::C3).n4.loop }

    it 'plays the fitted code bit for bit, every param a bounded knob of the track' do
      fit = MB::Sound::FitPatch.save(:lead_fit, LEAD_CODE, LEAD_PARAMS)
      _, want = run(->(_s) { MB::Sound.track(:lead) { |c| LEAD_BLOCK.(c) }; MB::Sound.bg(:lead, clip) })
      s, got = run(->(_s) { MB::Sound.track(:lead, fit); MB::Sound.bg(:lead, clip) })
      expect(want.abs.max).to be > 0.2 # (0.82 before the master's -10 dB: the softclip shapes it)
      expect(got).to eq(want)
      expect(s.knobs.keys).to include(:"lead/cutoff", :"lead/resonance", :"lead/attack", :"lead/clip")
      expect(s.knobs[:"lead/cutoff"].spec.range).to eq(100.0..8000.0)
      expect(s.knobs[:"lead/cutoff"].value).to eq(1234.5)
    end

    it 'turns live knobs live and makes a clip threshold a build knob' do
      fit = MB::Sound::FitPatch.save(:lead_fit, LEAD_CODE, LEAD_PARAMS)
      _, want = run(->(_s) { MB::Sound.track(:lead, fit); MB::Sound.bg(:lead, clip) })
      s, got = run(->(_s) { MB::Sound.track(:lead, fit); MB::Sound.bg(:lead, clip) }, acts: { 10 => ->(_s) { MB::Sound.turn(:"lead/cutoff", 300.0, smooth: 0) } })
      expect(got[0...8000]).to eq(want[0...8000])
      expect((got[9000..] - want[9000..]).abs.max).to be > 0.05
      expect(s.arrangement.build_knob?(:"lead/clip")).to eq(true)
      expect(s.arrangement.build_knob?(:"lead/cutoff")).to eq(false)
    end

    it "renders in the sound-design screen's RENDER pane (a param read by lp4 straight from the track's knob)" do
      fit = MB::Sound::FitPatch.save(:lead_fit, LEAD_CODE, LEAD_PARAMS)
      s, = run(->(_s) { MB::Sound.track(:lead, fit); MB::Sound.bg(:lead, clip) }, buffers: 4)
      ui = MB::Sound::UI
      poll = ui::Poll.new(s)
      ui::Inspect.target = { track: :lead, node: nil }
      src = poll.call(%i[inspect render]).first.render_source
      job = ui::PatchRender::Job.new(seq: 1, key: [:lead, 1], source: src, input: ui::PatchRender.input(src, 0.5),
                                     knobs: s.knobs.map { |n, k| [n, k.value, k.spec] }, seconds: 0.5)
      r = ui::PatchRender.render(job)
      expect(r.error).to be_nil
      expect(r.lufs).to be_finite
    ensure
      ui::Inspect.target = nil
      poll&.close
    end

    it 'renders a fitted kit voice in the RENDER pane through a copy of the kit' do
      params = { tune: (30.0..110.0).at(51.328155), decay: (0.1..2.0).at(0.468972), clip: (0.2..1.0).at(0.205115) }
      fit = MB::Sound::FitPatch.save(:kick_fit, KICK_CODE, params)
      s, = run(->(_s) { MB::Sound.track(:kick, fit); MB::Sound.bg(:kick, MB::Sound.seq(MB::Sound::C2).n4.loop) }, buffers: 4)
      ui = MB::Sound::UI
      poll = ui::Poll.new(s)
      ui::Inspect.target = { track: :kick, node: nil }
      src = poll.call(%i[inspect render]).first.render_source
      expect(src.synth).to be_a(ui::PatchRender::KitCopy)
      job = ->(tune) {
        knobs = s.knobs.map { |n, k| [n, n == :"kick/tune" ? tune : k.value, k.spec] }
        ui::PatchRender::Job.new(seq: 1, key: [:kick, tune], source: src, input: ui::PatchRender.input(src, 0.5), knobs: knobs, seconds: 0.5)
      }
      cache = {}
      a = ui::PatchRender.render(job.(51.328155), cache: cache)
      b = ui::PatchRender.render(job.(90.0), cache: cache)
      again = ui::PatchRender.render(job.(51.328155), cache: cache)
      expect(a.error).to be_nil
      expect(a.peak).to be > -30
      expect(again.hi).to eq(a.hi) # (reset to the same state every render)
      expect(b.hi).not_to eq(a.hi) # (the copy reads the job's knob values)
    ensure
      cache&.[](:copies)&.each_value(&:close)
      ui::Inspect.target = nil
      poll&.close
    end

    it 'plays a fitted kit voice from a clip' do
      params = { tune: (30.0..110.0).at(51.328155), decay: (0.1..2.0).at(0.468972), clip: (0.2..1.0).at(0.205115) }
      fit = MB::Sound::FitPatch.save(:kick_fit, KICK_CODE, params)
      s, got = run(->(_s) { MB::Sound.track(:kick, fit); MB::Sound.bg(:kick, MB::Sound.seq(MB::Sound::C2).n4.loop) })
      expect(got.abs.max).to be > 0.05
      expect(s.knobs[:"kick/tune"].value).to eq(51.328155)
    end
  end

  # The shapes of the three hand-tune queue fits that didn't load
  # (fit-patch-2; synthetic numbers, no private code): a clap built from
  # bursts, Repeats, and Drums.decay_env; a voice inside with_seed; and a
  # then block calling times.  Each loads with every fitted number a param
  # and plays the code's samples, bit for bit.
  describe 'the queue shapes (fit-patch-2)' do
    CLAP_CODE = "kit(CLIP, seed: 1) { voice(:clap) { |h| bursts = h.bursts(4, 0.0093, falloff: 0.8821); " \
                'env = MB::Sound::Drums.decay_env(bursts, 0.0164, curve: 30) + MB::Sound::Drums.decay_env(MB::Sound::Drums::Repeats.new(h.t, [[0.0271, 1.0]]), 0.4412) * 0.2135; ' \
                'MB::Sound.noise.filter(:bandpass, cutoff: 1184.37, quality: 2.1093).filter(:highpass, cutoff: 312.55, quality: 0.7) * env * 3.1 } }'.freeze
    CLAP_PARAMS = {
      spacing: (0.004..0.02).at(0.0093), falloff: (0.4..1.2).at(0.8821), burst_decay: (0.002..0.03).at(0.0164), tail_at: (0.01..0.05).at(0.0271),
      decay: (0.05..1.0).at(0.4412), tail: (0.05..2.0).at(0.2135), bandpass: (400.0..4000.0).at(1184.37), quality: (0.4..5.0).at(2.1093),
      highpass: (100.0..3000.0).at(312.55),
    }.freeze
    SEEDED_CODE = 'play ((with_seed(1) { synth(CLIP, voices: 1) { |v| v.hz.unison(3, detune: 9.5.cents, mix: 0.75) { |c, _i| c.saw }' \
                  '.lp4(1530.2, resonance: 0.1234) * v.env(0.0345, 0.5342, 0.2681, 0.05) + noise.lp4(4275.0, resonance: 0.7655, mode: :bp2) * 0.0195 } }) ' \
                  '* 0.7991 + -0.0208).then { |u| u + u * u * 0.5493 }.softclip(0.9976, 1.0)'.freeze
    SEEDED_PARAMS = {
      cutoff: (30.0..18000.0).at(1530.2), reso: (0.0..1.0).at(0.1234), attack: (0.0003..6.0).at(0.0345), st_f: (2000.0..12000.0).at(4275.0),
      st_q: (0.4..0.97).at(0.7655), st_lvl: (0.0..0.6).at(0.0195), sh_pre: (0.1..10.0).at(0.7991), sh_bias: (-0.5..0.5).at(-0.0208),
      sh_sq: (-1.0..1.0).at(0.5493), sh_th: (0.05..1.0).at(0.9976),
    }.freeze
    PHASER_CODE = 'play (synth(CLIP, voices: 1) { |v| v.hz.saw * v.env(0.0006, 0.0922, 0.926, 0.05) }.then { |x| ' \
                  'c = 2 ** (0.4051.hz.lfo.triangle * 1.6244) * 665.1; ap = x; 4.times { ap = ap.filter(:allpass, cutoff: c, quality: 0.5) }; x + ap * 0.221 })'.freeze
    PHASER_PARAMS = { ph_depth: (0.0..3.0).at(1.6244), ph_f: (100.0..8000.0).at(665.1), ph_q: (0.3..2.0).at(0.5), ph_mix: (0.0..1.0).at(0.221) }.freeze

    let(:clip) { MB::Sound.seq(MB::Sound::Ds2, MB::Sound::Ds2.n8, MB::Sound::C4.n8).n4.loop }

    # The code as the console runs it, playing +clip+, and the fit's
    # document loaded with +clip+ as its midi input (another root seed, so
    # only the code's own seeds count).
    def renders(code, params)
      fit = MB::Sound::FitPatch.save(:shape_fit, code, params)
      MB::Sound.seed(5)
      want = RecipeHelpers.render(RecipeHelpers.eval_recipe(MB::Sound::FitPatch.unwrap(code).gsub('CLIP', 'clip'), clip: clip), buffers: 30, size: 800)
      MB::Sound.seed(77)
      got = RecipeHelpers.render(MB::Sound::GraphIO.load(fit.text, inputs: { midi: clip }), buffers: 30, size: 800)
      [fit, want, got]
    end

    it 'makes a clap from bursts, Repeats, and Drums.decay_env with every fitted number a param' do
      fit, want, got = renders(CLAP_CODE, CLAP_PARAMS)
      expect(fit.missing).to eq([])
      expect(fit.text).to include('h.bursts(4, spacing, falloff: falloff)', 'MB::Sound::Drums::Repeats.new(h.t, [[tail_at, 1.0]])',
                                  'MB::Sound.noise.filter(:bandpass, cutoff: bandpass, quality: quality)')
      expect(want[0].abs.max).to be > 0.1
      expect(got).to eq(want)
    end

    it "makes the clap's spacing a build knob on a track and its filter a live one" do
      fit = MB::Sound::FitPatch.save(:clap_fit, CLAP_CODE, CLAP_PARAMS)
      s, got = run(->(_s) { MB::Sound.track(:clap, fit); MB::Sound.bg(:clap, clip) }, buffers: 20)
      expect(got.abs.max).to be > 0.02
      expect(s.arrangement.build_knob?(:"clap/spacing")).to eq(true)
      expect(s.arrangement.build_knob?(:"clap/tail_at")).to eq(true)
      expect(s.arrangement.build_knob?(:"clap/bandpass")).to eq(false)
    end

    it 'loads a voice inside with_seed, its draws following the seed and not the root' do
      fit, want, got = renders(SEEDED_CODE, SEEDED_PARAMS)
      expect(fit.missing).to eq([])
      expect(fit.text).to include('with_seed(1) { synth(midi, voices: 1)', '.then { |u| u + u * u * sh_sq }.softclip(sh_th, 1.0)')
      expect(want[0].abs.max).to be > 0.1
      # (within a float32 step: lp4 reads its cutoff and resonance params as
      # constant nodes)
      expect(RecipeHelpers.max_diff(want, got)).to be < 1e-6
      MB::Sound.seed(5)
      other = RecipeHelpers.render(MB::Sound::GraphIO.load(fit.text.sub('with_seed(1)', 'with_seed(2)'), inputs: { midi: clip }), buffers: 30, size: 800)
      expect(RecipeHelpers.max_diff(want, other)).to be > 0.01
    end

    it 'writes out a times loop in a then block, its numbers params at every copy' do
      fit, want, got = renders(PHASER_CODE, PHASER_PARAMS)
      expect(fit.missing).to eq([])
      expect(fit.sites.count { |x| x.name == :ph_q }).to eq(4)
      expect(fit.text).to include('ap = x; ap = ap.filter(:allpass, cutoff: c, quality: ph_q); ap = ap.filter(:allpass, cutoff: c, quality: ph_q); ')
      expect(fit.text).not_to include('times')
      expect(want[0].abs.max).to be > 0.1
      expect(got).to eq(want)
    end

    it 'leaves numbers in runtime blocks and at number-only settings as numbers, saying why' do
      code = 'synth(CLIP) { |v| v.hz.saw.quantize(0.0123).proc { |buf| buf * 0.4321 } * 0.6789.constant }'
      params = MB::Sound::FitPatch.declare(step: (0.001..0.1).at(0.0123), g: (0.0..1.0).at(0.4321), lvl: (0.0..1.0).at(0.6789))
      _, sites, missing, skipped = MB::Sound::FitPatch.document(code, params, name: :x)
      expect(sites).to eq([])
      expect(missing).to eq(%i[step g lvl])
      expect(skipped[:step]).to match(/0\.0123 is at a setting that takes only numbers \(quantize\(0\): a node increment plays the plain live bitcrusher/)
      expect(skipped[:g]).to eq("0.4321 is inside a proc block (runs while playing; params can't go there)")
      expect(skipped[:lvl]).to match(/at a setting that takes only numbers \(constant\(receiver\)/)
    end
  end

  describe '.unroll' do
    it 'writes out times statements, reading the block parameter as each index' do
      expect(MB::Sound::FitPatch.unroll('a = x; 3.times { |i| a = a.delay(i * 0.001) }; a'))
        .to eq('a = x; a = a.delay(0 * 0.001); a = a.delay(1 * 0.001); a = a.delay(2 * 0.001); a')
      expect(MB::Sound::FitPatch.unroll("a = x\n2.times do\n  2.times { a = a.softclip }\nend\na"))
        .to eq("a = x\na = a.softclip; a = a.softclip; a = a.softclip; a = a.softclip\na")
      expect(MB::Sound::FitPatch.unroll('a = x; 0.times { a = a.softclip }; a')).to eq('a = x; nil; a')
    end

    it 'leaves a times whose value is used, or that has no literal count, for the loader to name' do
      ['3.times { x }', 'a = 3.times { x }; a', 'n.times { x }; y'].each do |code|
        expect(MB::Sound::FitPatch.unroll(code)).to eq(code)
      end
      expect { MB::Sound::FitPatch.save(:x, 'synth(CLIP) { |v| a = v.hz.saw; 3.times { a }.then { a } }', { g: (0.0..1.0).at(0.5) }) }
        .to raise_error(MB::Sound::FitPatch::Error, /times/)
      expect { MB::Sound::FitPatch.unroll('a = x; 99.times { a = a.softclip }; a', :big) }.to raise_error(MB::Sound::FitPatch::Error, /99 copies \(at most 32\)/)
    end
  end

  describe 'tune (the one-liner)' do
    before do
      allow(MB::Sound::UI).to receive(:show).and_return(nil)
      allow(MB::Sound::UI::Design).to receive(:terminal?).and_return(true)
    end

    after do
      MB::Sound::UI::Inspect.target = nil
      MB::Sound::UI::Design.instance_variable_set(:@open, false)
      MB::Sound::UI::Design.instance_variable_set(:@last, nil)
    end

    it 'makes the fit patch, opens it in design on its track, and sets up the reference' do
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      @sessions << s
      ref = MB::Sound::Sample.new([Numo::SFloat.new(9600).rand(-0.2, 0.2)], name: 'noise')
      o = MB::Sound::Session.with_context(session: s) { MB::Sound.tune(:lead, LEAD_CODE, ref: ref, play: MB::Sound.seq(MB::Sound::A2).n4.loop, **LEAD_PARAMS) }
      expect(o.fit.name).to eq(:lead_fit)
      expect(o.opened.to_s).to start_with('design :lead: lead_fit on track :lead (new)')
      expect(o.pair).to have_attributes(track: :lead, ref: :lead_ref, hearing: :patch)
      expect(o.to_s).to include('fit patch lead_fit', 'ab :lead: hearing the patch', 'take.save')
      expect(s.arrangement.tracks.keys).to include(:lead, :lead_ref)
    end
  end
end
