require_relative '../../../../support/sf2_writer'

# A track's effect insert (library-2; the maintainer, 2026-10-30: "Build fx:
# slot"): `track :keys, instrument, fx: L.fx.reverb.hall`, `fx :keys, ...`
# swapping it at the launch point with the instrument's state carried and
# the old effect's tail spilling, undo, set documents, and the errors.
RSpec.describe(MB::Sound::Arrangement::Fx, :aggregate_failures) do
  KEYS_RIFF = MB::Sound.seq(MB::Sound::A3, MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8.loop

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  # A Session that runs +setup+, then plays +buffers+ buffers (+acts+ {
  # buffer => Proc } on the way); returns [session, left].
  def run(setup, buffers: 120, acts: {})
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

  it 'plays the instrument through the insert, bit for bit like the effect after it in a patch block' do
    _, ref = run(->(_s) {
      MB::Sound.track(:keys) { |c| MB::Sound.preset(:funk_keys, midi: c).then(&MB::Sound::L.fx.hall) }
      MB::Sound.bg(:keys, KEYS_RIFF)
    })
    s, got = run(->(_s) { MB::Sound.track(:keys, :funk_keys, fx: MB::Sound::L.fx.hall); MB::Sound.bg(:keys, KEYS_RIFF) })
    expect(got).to eq(ref)
    expect(ref.abs.max).to be > 0.01
    expect(s.arrangement.tracks[:keys].fx).to eq([MB::Sound::L.fx.hall])
    # (the instrument's params are still the track's knobs; the effect's stay numbers)
    expect(s.knobs.keys).to include(:"keys/body", :"keys/decay")

    # Chains in order, Symbols, { family: :name }, Procs
    s2, = run(->(_s) { MB::Sound.track(:keys, :funk_keys, fx: [:juno1, { reverb: :plate }, ->(sig) { sig * 0.5 }]) }, buffers: 1)
    chain = s2.arrangement.tracks[:keys].fx
    expect(chain[0..1]).to eq([MB::Sound::L.fx.chorus.juno1, MB::Sound::L.fx.reverb.plate])
    expect(chain[2]).to be_a(Proc)
    expect(described_class.label(chain)).to eq('L.fx.juno1 + L.fx.reverb.plate + a block')
  end

  it "answers the maintainer's console guesses with the spelling that works (ux-friction-1)" do
    run(->(_s) {
      MB::Sound.track(:keys, :funk_keys)
      MB::Sound.track(:bass, :funk_keys)
      MB::Sound.bg(:keys, KEYS_RIFF.named(:riff))
    }, buffers: 2)
    within = ->(&b) { MB::Sound::Session.with_context(session: @sessions.last, &b) }
    # Two effects as two arguments: the list
    expect { within.() { MB::Sound.fx(:keys, :hall, :dub) } }.to raise_error(ArgumentError, /fx :keys takes one effect or a list: fx :keys, \[:hall, :dub\]/)
    # A clip's name given to bg or swap on another track: launch (as cue takes it)
    %w[bg swap].each do |cmd|
      expect { within.() { MB::Sound.public_send(cmd, :bass, :riff) } }.to raise_error(ArgumentError, /\A#{cmd} :bass, :riff: :riff is a clip's name; launch :bass, :riff plays it/)
    end
    expect(within.() { MB::Sound.launch(:bass, :riff) }.to_s).to start_with('bg :bass lands')
    # start takes no names; a latency profile is checked (seek 0 is the
    # start since ux-friction-3: form_spec's seek spellings)
    expect { within.() { MB::Sound.start(:keys) } }.to raise_error(ArgumentError, /start starts the transport .* bg :keys plays/)
    expect { MB::Sound.latency(:Low) }.to raise_error(ArgumentError, /latency :Low: no such profile \(did you mean :low\?\); the profiles are :low, :default, :video, :safe/)
  end

  it 'swaps the insert at the launch point, carrying the notes and letting the old tail ring, in one undo step' do
    plain = ->(_s) { MB::Sound.track(:keys, :funk_keys, fx: :hall); MB::Sound.bg(:keys, KEYS_RIFF) }
    _, base = run(plain, buffers: 200)
    s, got = run(plain, buffers: 200, acts: { 20 => ->(_s) { @entry = MB::Sound.fx(:keys, :dub) } })
    expect(@entry.to_s).to eq('bg :keys lands 2:1 (queued)')
    expect(s.journal.entries.last.to_s).to include('bg :keys')
    land = 96_000 # (bar 2 at 120 BPM)
    expect(got[0...land]).to eq(base[0...land])
    expect((got[land..] - base[land..]).abs.max).to be > 0.01
    expect(s.arrangement.tracks[:keys].fx).to eq([MB::Sound::L.fx.dub])
    expect(s.spills).to be >= 1 # (the hall's tail rang out under the new insert)

    MB::Sound::Session.with_context(session: s) {
      MB::Sound.undo(on: :now)
      expect(MB::Sound.fx(:keys)).to eq([MB::Sound::L.fx.hall])
      # The same effects again: nothing to rebuild
      expect(MB::Sound.fx(:keys, :hall)).to eq(:keys)
      # A new instrument keeps the insert; fx: :off (or fx :keys, :off) takes it out
      MB::Sound.track(:keys, :tine_piano)
      expect(MB::Sound.fx(:keys)).to eq([MB::Sound::L.fx.hall])
      MB::Sound.track(:keys, :tine_piano, fx: :off)
      expect(MB::Sound.fx(:keys)).to eq([])
    }
  end

  it 'says what it takes, and where effects go instead' do
    s, = run(->(_s) {
      MB::Sound.track(:keys, :funk_keys)
      MB::Sound.track(:pad, MB::Sound.seq(MB::Sound::A3).n1.loop.tone.saw.at(-20.db))
    }, buffers: 1)
    MB::Sound::Session.with_context(session: s) {
      expect { MB::Sound.fx(:keys, :plate) }.to raise_error(described_class::Error, /2 effects are named plate \(L\.fx\.reverb\.plate, L\.fx\.resonator\.plate\)/)
      expect { MB::Sound.fx(:keys, :hal) }.to raise_error(described_class::Error, /no effect :hal.*hall/m)
      expect { MB::Sound.fx(:keys, MB::Sound::L.inst.dnb_sub) }.to raise_error(described_class::Error, /L\.inst\.dnb_sub is an instrument, not an effect/)
      expect { MB::Sound.fx(:keys, 3) }.to raise_error(described_class::Error, /a library effect.*Integer/)
      expect { MB::Sound.fx(:pad, :hall) }.to raise_error(described_class::Error, /:pad plays a graph: its effects go in its graph/)
      expect { MB::Sound.fx(:nope, :hall) }.to raise_error(ArgumentError, /no track :nope/)
      expect { MB::Sound.track(:keys, :funk_keys, fx: :hal) }.to raise_error(described_class::Error, /no effect :hal/)

      # (fixes-15, the maintainer's `fx(:sub) { it.pan(1) }`: Ruby dropped
      # the block, nothing changed, nothing said so)
      expect { expect(MB::Sound.fx(:keys) { it.pan(1) }).to eq([]) }.to output(
        /warning: fx :keys takes its effect as an argument, not a block, so the block was ignored and nothing changed; give a Proc taking the track's signal: fx :keys, ->\(s\) \{ s\.pan\(1\) \}\n\z/
      ).to_stderr
      expect(s.arrangement.tracks[:keys].fx).to be_nil.or eq([])
    }
  end

  # (the maintainer's take, 2026-11-21: `kit = sf2(...)`, `track :drums,
  # kit`, a generator on it, then `fx :drums, ->{ it.compress(threshold:
  # -30) }`: "Why can I not put effects on a soundfont track?"  The
  # SoundFont was a graph track; a sampler instrument given to `track` is
  # now a patch track, as `track(:drums) { |c| kit.sampler(c, voices: 8) }`)
  describe 'a SoundFont or sampler instrument as the track' do
    def kit_path
      path = tmp_path('kit.sf2')
      return path if File.exist?(path)
      SF2Writer.write(path,
        samples: [
          { name: 'thump', data: Array.new(4000) { |i| Math.sin(2 * Math::PI * 60 * i / 44100.0) * Math.exp(-i / 900.0) }, rate: 44100, pitch: 36 },
          { name: 'tick', data: Array.new(2000) { |i| Math.sin(2 * Math::PI * 3000 * i / 44100.0) * Math.exp(-i / 300.0) }, rate: 44100, pitch: 60 },
        ],
        instruments: [{ name: 'Kit', zones: [{ key_range: [0, 37], sample_id: 0 }, { key_range: [38, 127], sample_id: 1 }] }],
        presets: [{ name: 'Spec Kit', program: 0, zones: [{ instrument: 0 }] }, { name: 'GM Kit', bank: 128, program: 0, zones: [{ instrument: 0 }] }])
    end

    let(:beat) { MB::Sound::L.gen.beat.techno.call(seed: 5) }

    it 'plays clips through an fx insert, bit for bit like the block form with the effect inside' do
      font = MB::Sound.sf2(kit_path)
      comp = ->(sig) { sig.compress(threshold: -30.db) }
      _, ref = run(->(_s) { MB::Sound.track(:drums) { |c| comp.(font.sampler(c, voices: 8)) }; MB::Sound.bg(:drums, beat) })
      s, got = run(->(_s) { MB::Sound.track(:drums, font); MB::Sound.bg(:drums, beat); MB::Sound.fx(:drums, comp) })
      expect(ref.abs.max).to be > 0.01
      expect(got).to eq(ref)
      expect(s.arrangement.tracks[:drums]).to be_patch
      expect(s.arrangement.tracks[:drums].fx).to eq([comp])
      # (the compressor is heard: the dry kit differs)
      _, dry = run(->(_s) { MB::Sound.track(:drums, font); MB::Sound.bg(:drums, beat) })
      expect((dry - got).abs.max).to be > 0.01

      # fx: on the track line, a preset as the instrument, and the errors
      s2, = run(->(_s) { MB::Sound.track(:d2, font[128, 0], fx: :hall) }, buffers: 1)
      expect(s2.arrangement.tracks[:d2].fx).to eq([MB::Sound::L.fx.hall])
      MB::Sound::Session.with_context(session: s2) {
        expect { MB::Sound.track(:d3, font) { |c| c } }.to raise_error(ArgumentError, /a sampler instrument or a patch block, not both/)
        expect { MB::Sound.track(:d3, font, :funk_keys) }.to raise_error(ArgumentError, /one instrument \(got two\)/)
        MB::Sound.track(:pad, 0.1.constant)
        expect { MB::Sound.fx(:pad, :hall) }.to raise_error(described_class::Error, /:pad plays a graph: its effects go in its graph/)
      }
    end

    it 'saves as the track line it was given (a font as its preset) and loads back to the same kind of track' do
      s, = run(->(_s) {
        MB::Sound.track(:drums, beat, MB::Sound.sf2(kit_path), fx: :hall)
        MB::Sound.track(:gm, MB::Sound.sf2(kit_path, [128, 0]))
      }, buffers: 1)
      text = MB::Sound::Session.with_context(session: s) { MB::Sound::GraphIO::SetWriter.new(s.arrangement).to_s }
      expect(text).to include(%(track :drums, drums, sf2("#{kit_path}", preset: [0, 0]), fx: :hall\n))
      expect(text).to include(%(track :gm, sf2("#{kit_path}", preset: [128, 0])\n))
      s2 = MB::Sound::Session.new(realtime: false)
      @sessions << s2
      MB::Sound::Session.with_context(session: s2) { MB::Sound::GraphIO.load(text.gsub(kit_path, 'kit.sf2'), session: s2, base_dir: File.dirname(kit_path)) }
      expect(s2.arrangement.tracks.transform_values(&:patch?)).to eq(drums: true, gm: true)
      expect(s2.arrangement.tracks[:drums].fx).to eq([MB::Sound::L.fx.hall])
    end

    it 'rings its effect out through a pause, the notes released' do
      font = MB::Sound.sf2(kit_path)
      s, = run(->(_s) { MB::Sound.track(:drums, font, fx: ->(sig) { sig.delay(0.25, feedback: 0.6) }); MB::Sound.bg(:drums, beat) }, buffers: 60)
      s.pause_transport
      tail = SpecBuffers.join(Array.new(60) { s.process_buffer[0].dup })
      # (the echoes go on after the pause, then die away)
      expect(tail[12000...24000].abs.max).to be > 0.001
      expect(tail[-4800..].abs.max).to be < tail[0...12000].abs.max
    end
  end

  it 'saves the insert in set documents and loads it back' do
    s, = run(->(_s) { MB::Sound.track(:keys, :funk_keys, fx: [:juno1, { reverb: :plate }]) }, buffers: 1)
    text = MB::Sound::Session.with_context(session: s) { MB::Sound::GraphIO::SetWriter.new(s.arrangement).to_s }
    expect(text).to include("track :keys, :funk_keys, fx: [:juno1, { reverb: :plate }]\n")
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.track(:bass, :dnb_sub, fx: ->(sig) { sig * 0.5 })
      expect { MB::Sound::GraphIO::SetWriter.new(s.arrangement).to_s }.to raise_error(MB::Sound::GraphIO::DumpError, /track :bass: its fx: has a block/)
    }
    s2 = MB::Sound::Session.new(realtime: false)
    @sessions << s2
    MB::Sound::Session.with_context(session: s2) { MB::Sound::GraphIO.load(text, session: s2) }
    expect(s2.arrangement.tracks[:keys].fx).to eq([MB::Sound::L.fx.chorus.juno1, MB::Sound::L.fx.reverb.plate])
  end
end
