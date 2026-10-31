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
      expect { MB::Sound.fx(:pad, :hall) }.to raise_error(described_class::Error, /a graph track's effects go in its graph/)
      expect { MB::Sound.fx(:nope, :hall) }.to raise_error(ArgumentError, /no track :nope/)
      expect { MB::Sound.track(:keys, :funk_keys, fx: :hal) }.to raise_error(described_class::Error, /no effect :hal/)
    }
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
