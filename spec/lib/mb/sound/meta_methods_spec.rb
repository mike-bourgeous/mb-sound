# The console's `meta` and `metas` (source-meta-1; MetaMethods, the
# Session's Meta::Store): the contract importers write against, what
# metadata survives, and that it is no part of the sound.
require 'mb/sound/help'
require_relative '../../../support/meta_song'
RSpec.describe(MB::Sound::MetaMethods, :aggregate_failures) do
  let(:sessions) { [] }
  let(:track) { MB::Sound::MetaSong::TRACK }
  let(:bus) { MB::Sound::MetaSong::BUS }
  let(:set) { MB::Sound::MetaSong::SET }

  after { sessions.each(&:close) }

  def session(size = 800)
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: size, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  def within(s, &block)
    MB::Sound::Session.with_context(session: s) { MB::Sound.instance_exec(&block) }
  end

  def render(s, buffers)
    Array.new(buffers) { s.process_buffer.map(&:dup) }.transpose.map { |c| SpecBuffers.join(c) }
  end

  def simple_track(s, name = :a3)
    within(s) { track(name, q: 1) { |clip| clip.synth(voices: 1) { |v| v.hz.triangle * v.amp_env(0.003, 0.1, 0.5, 0.05) } * 0.2 } }
  end

  describe 'the contract importers write against' do
    it 'gives named pieces and the set metadata, and reads it back as frozen Hashes' do
      s = session
      track_meta = track
      bus_meta = bus
      set_meta = set
      within(s) do
        meta :a3, source: { format: :acd, kind: :track, at: 0x12340, bytes: 5678, name: "the track's own name", fields: { color: 3, height: 80 } }
        meta :fx1, source: bus_meta
        meta source: { format: :acd, file: 'project.acd', bytes: 1_234_567, version: '7.0', unread: 0.19 }
      end
      simple_track(s)
      within(s) { bus(:fx1) { |sig| sig.softclip(0.5, 0.9) } }

      expect(within(s) { meta :a3 }).to eq(source: track_meta)
      expect(within(s) { meta :fx1 }).to eq(source: bus_meta)
      expect(within(s) { meta }).to eq(source: set_meta)
      expect(within(s) { meta :nothing }).to eq({})
      expect([within(s) { meta :a3 }, within(s) { meta }, within(s) { meta :nothing }]).to all(be_frozen)
      expect(within(s) { meta(:a3)[:source][:fields] }).to be_frozen
      expect(s.metadata[:a3]).to equal(within(s) { meta :a3 })
    end

    it 'merges top-level keys, before or after the piece is defined' do
      s = session
      track_meta = track
      within(s) { meta :a3, source: track_meta }
      simple_track(s)
      expect(within(s) { meta :a3, notes: 'x' }).to eq(source: track_meta, notes: 'x')
      expect(within(s) { meta :a3, { tags: %w[bass sub] }, notes: 'y' }).to eq(source: track_meta, notes: 'y', tags: %w[bass sub])
      expect(within(s) { meta :a3, source: { format: :mod } }[:source]).to eq(format: :mod)
      expect(within(s) { meta({ notes: 'the set' }) }).to eq(notes: 'the set')
      expect(within(s) { metadata :a3 }).to equal(within(s) { meta :a3 })
      # every Session::Names kind, and structured names
      within(s) do
        knob :cut, 800.0, range: 100.0..4000.0
        mutes :rhythm, :a3
        meta :cut, source: { kind: :envelope, range: [0, 127] }
        meta :rhythm, notes: 'a group'
        meta :"a3/level", source: { kind: :envelope }
        meta :master, source: { kind: :bus, name: 'Master' }
      end
      expect(s.metadata.names).to eq(%i[a3 cut rhythm a3/level master])
    end

    it 'forgets with nil' do
      s = session
      within(s) { meta :a3, notes: 'x'; meta notes: 'set' }
      expect(within(s) { meta :a3, nil }).to eq({})
      expect(within(s) { meta :a3 }).to eq({})
      expect(within(s) { meta }).to eq(notes: 'set')
      expect(within(s) { meta nil, nil }).to eq({})
      expect(s.metadata).to be_empty
    end

    it 'rejects anything but plain Ruby, naming the key path, and changes nothing then' do
      s = session
      within(s) { meta :a3, notes: 'kept' }
      expect { within(s) { meta :a3, source: { fields: { env: 440.hz } } } }.to raise_error(ArgumentError, /\Ameta\[:source\]\[:fields\]\[:env\] is a/)
      expect { within(s) { meta :a3, source: { list: [1, [2, Time.at(0)]] } } }.to raise_error(ArgumentError, /meta\[:source\]\[:list\]\[1\]\[1\] is a Time/)
      expect { within(s) { meta :a3, 'notes' => 'x' } }.to raise_error(ArgumentError, /top-level metadata keys are Symbols/)
      expect { within(s) { meta 'a3', notes: 'x' } }.to raise_error(ArgumentError, /meta takes a piece's name as a Symbol/)
      expect { within(s) { meta :a3, [1, 2] } }.to raise_error(ArgumentError, /metadata is a Hash of plain values/)
      expect(within(s) { meta :a3 }).to eq(notes: 'kept')
    end
  end

  describe 'metas' do
    it 'lists a line per name, the set under nil, with each piece\'s kind and the set\'s file' do
      s = session
      track_meta = track
      bus_meta = bus
      set_meta = set
      expect(within(s) { metas }).to eq({})
      simple_track(s)
      within(s) do
        bus(:fx1) { |sig| sig.softclip(0.5, 0.9) }
        meta :a3, source: track_meta
        meta :fx1, source: bus_meta.except(:kind)
        meta :ghost, notes: 'x'
        meta source: set_meta
      end
      expect(within(s) { metas }).to eq(
        nil => 'from "project.acd" (acd "7.0"), set, 1.2 MB, 19% unread',
        a3: %(from "project.acd", track "the track's own name" at 0x12340, 5.5 KB, 2 fields carried),
        fx1: 'from "project.acd", bus #2, 1 field carried',
        ghost: 'not defined, notes "x"'
      )
    end

    it 'shows in `now` as one line' do
      s = session
      set_meta = set
      text = within(s) { MB::U.remove_ansi(MB::Sound::Help::Now.new(s).to_s) }
      expect(text).not_to include('metadata')
      within(s) { meta source: set_meta; meta :a3, notes: 'x'; meta :b, notes: 'y' }
      text = within(s) { MB::U.remove_ansi(MB::Sound::Help::Now.new(s).to_s) }
      expect(text).to include('metadata from "project.acd" (acd "7.0"), set, 1.2 MB, 19% unread; 2 pieces with metadata (metas lists it)')
    end
  end

  describe 'what metadata survives' do
    it 'stays through swaps, scene changes, undo, and redo' do
      s = session
      track_meta = track
      simple_track(s)
      within(s) do
        a = seq(MB::Sound::C3, MB::Sound::E3).n8.loop
        b = seq(MB::Sound::G3, MB::Sound::B3).n8.loop
        scene :one, a3: a
        scene :two, a3: b
        meta :a3, source: track_meta
        go :one, on: :now
      end
      render(s, 30)
      within(s) { go :two, on: :now }
      render(s, 30)
      within(s) { swap :a3, seq(MB::Sound::D3).n4.loop, on: :now }
      render(s, 30)
      expect(s.metadata[:a3]).to eq(source: track_meta)
      within(s) { undo; undo at: :now }
      render(s, 30)
      expect(s.metadata[:a3]).to eq(source: track_meta)
      within(s) { redo! }
      render(s, 30)
      expect(s.metadata[:a3]).to eq(source: track_meta)
      # (metadata is not an undo step: undo never takes it away)
      within(s) { meta :a3, notes: 'later'; undo }
      expect(s.metadata[:a3]).to eq(source: track_meta, notes: 'later')
    end

    it 'stays with the name through untrack: undo or a new track of the name has it, until it is forgotten' do
      s = session
      track_meta = track
      simple_track(s, :extra)
      within(s) { meta :extra, source: track_meta }
      within(s) { untrack :extra }
      expect(s.names.kind(:extra)).to be_nil
      expect(s.metadata[:extra]).to eq(source: track_meta)
      expect(within(s) { metas }[:extra]).to start_with('from acd, track ')
      within(s) { undo }
      expect(s.names.kind(:extra)).to eq(:track)
      expect(s.metadata[:extra]).to eq(source: track_meta)
      within(s) { untrack :extra }
      simple_track(s, :extra)
      expect(s.metadata[:extra]).to eq(source: track_meta)
      within(s) { untrack :extra; meta :extra, nil }
      simple_track(s, :extra)
      expect(s.metadata[:extra]).to eq({})
    end

    it 'belongs to its Session: another Session starts without it' do
      a = session
      b = session
      within(a) { meta :a3, notes: 'x' }
      expect(b.metadata).to be_empty
    end

    it 'replays with a take: `meta` lines run again, `metas` is skipped as a listing' do
      s = session
      seen = []
      stub_const('MB::Sound::MetaSeen', seen)
      t = MB::Sound::Take.new(session: s)
      b = MB::Sound::Take.console_binding
      [
        'track(:a3, q: 1) { |c| c.number * 0.01 }',
        'meta :a3, source: { format: :acd, kind: :track, at: 0x12340, fields: { color: 3 } }',
        'meta source: { format: :acd, file: "project.acd" }',
        'metas',
        'bg :a3, seq(C3).n4.loop, on: :now',
        'MetaSeen << [meta(:a3), meta]',
      ].each_with_index do |code, i|
        MB::Sound::Session.with_context(session: s) { t.line(code, b) }
        (i * 3).times { s.process_buffer }
      end
      text = t.to_ruby
      expect(text).to include('meta :a3, source: { format: :acd, kind: :track, at: 0x12340, fields: { color: 3 } }')
      expect(text).to include('# skipped (foreground): metas')
      seen.clear
      t.replay.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), tail: 0)
      expect(seen).to eq([[{ source: { format: :acd, kind: :track, at: 0x12340, fields: { color: 3 } } }, { source: { format: :acd, file: 'project.acd' } }]])
    end
  end

  describe 'no part of the sound' do
    it 'renders bit for bit the same with and without metadata (before, between, mid-song, on nodes)' do
      mixes = [false, true].map do |carried|
        s = session
        MB::Sound::Session.with_context(session: s) { MB::Sound::MetaSong.song(carried) }
        mix = render(s, 240) # 4 bars
        [mix, s]
      end
      (plain, quiet), (carried, loud) = mixes
      expect(plain[0].abs.max).to be > 0.05
      expect(carried.map(&:to_binary) == plain.map(&:to_binary)).to be(true)
      expect(quiet.metadata).to be_empty
      expect(loud.metadata.names).to eq(%i[fx1 pad ghost a3]) # (:a3 forgotten and given again mid-song)
      expect(loud.metadata[:a3]).to eq(source: track)
      expect(loud.metadata[:pad]).to eq(source: { kind: :track, at: 99 })
      # (the same changes landed on the same frames)
      landed = ->(s) { s.journal.changes.map { |e| [e.kind, e.subject, e.status, e.lands] } }
      expect(landed.(loud)).to eq(landed.(quiet))
    end

    it 'renders the same at another buffer size too (within the suite\'s -80 dB)' do
      a, b = [800, 367].map do |size|
        s = session(size)
        MB::Sound::Session.with_context(session: s) { MB::Sound::MetaSong.song(true) }
        render(s, (96_000.0 / size).ceil)[0][0...96_000]
      end
      expect((a - b).abs.max).to be <= 10**(-80 / 20.0)
    end

    it 'keeps the Session\'s instance variable layout' do
      s = session
      before = s.instance_variables
      MB::Sound::Session.with_context(session: s) { MB::Sound::MetaSong.song(true) }
      render(s, 200)
      expect(s.instance_variables - before).to eq([])
      expect(before).to include(:@metadata)
    end
  end
end
