require_relative '../../../../support/module_writer'

# Tracker sets (tracker-1): the flow, looping, play/render, and set
# documents with the samples as bundle assets.
RSpec.describe(MB::Sound::Tracker::Set, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def session
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  def path
    @path ||= begin
      p0 = w.pattern(4, { [0, 0] => { note: 60, sample: 1 }, [4, 1] => { note: 72, sample: 2, effect: 10, param: 0x02 },
                          [8, 2] => { note: 64, sample: 1, effect: 0, param: 0x37 }, [9, 3] => { note: 60, sample: 2, effect: 9, param: 1 } })
      p1 = w.pattern(4, { [0, 3] => { note: 67, sample: 1 }, [15, 0] => { effect: 11, param: 1 } })
      w.mod(tmp_path('song.mod'), samples: [{ name: 'saw', data: w.saw(2000), loop: [1000, 2000] }, { name: 'click', data: w.click(400) }],
                                  patterns: [p0, p1], orders: [0, 1])
    end
  end

  def play(s, buffers)
    Array.new(buffers) { s.process_buffer.map(&:dup) }.transpose.map { |c| SpecBuffers.join(c) }
  end

  it 'lists its scenes and clips, and loops back with loop: true' do
    set = MB::Sound.mod_import(path)
    expect(set.scenes).to eq(%i[p00 p01])
    expect(set.restart).to eq(1)
    expect(set[:p01].keys).to eq(set.tracks)
    expect { set[:p09] }.to raise_error(ArgumentError, /No scene :p09/)
    expect(set.to_s).to match(/mod "song" as a set \(musical\): 4 tracks, 2 scenes, 2 sections, 0:10, loops/)
    s = session
    form = MB::Sound::Session.with_context(session: s) { set.setup(loop: true) }
    expect(form.to_ruby).to include('label :loop', 'goto :loop')
    expect(s.arrangement.tracks.keys).to eq(set.tracks)
    expect(MB::Sound::Session.with_context(session: s) { set.form }.to_ruby).not_to include('goto')
  end

  it 'saves a bundle with the samples as assets that loads and plays the same' do
    set = MB::Sound.mod_import(path)
    doc = File.join(File.dirname(path), 'song.mbg.rb')
    out = MB::Sound::GraphIO.save(doc, set)
    expect(out).to end_with('song.mbg/song.mbg.rb')
    text = File.read(out)
    expect(text).to include('kind: :set', 'asset "assets/01_saw.flac"', 'asset "assets/02_click.flac"', 'lanes: { smooth: 0.0015, law: :linear }')
    expect(text).to include('flow do', 'p00 ', 'p01 ')

    a = session
    MB::Sound::Session.with_context(session: a) { set.play(on: :now) }
    ref = play(a, 300)
    b = session
    MB::Sound::Session.with_context(session: b) {
      loaded = MB::Sound::GraphIO.load(out, session: b)
      MB::Sound.play_form(loaded.form, on: :now)
    }
    expect(play(b, 300)).to eq(ref)
    expect(ref[0].abs.max).to be > 0.1
  end

  it 'renders and plays through render and play' do
    set = MB::Sound.mod_import(path, mode: :hardware)
    file = tmp_path('song.flac')
    secs = MB::Sound.render(file, set, gain: -12.db)
    expect(secs).to be_within(0.05).of(set.seconds) # (the song stops at its end: looping samples don't ring on)
    expect(MB::Sound.render(file, gain: -12.db, overwrite: true) { set.play }).to eq(secs)
    expect { MB::Sound::Playable.graph(set) }.to raise_error(MB::Sound::Playable::Unplayable, /play song/)
    # (a module file renders as its set)
    expect(MB::Sound.render(file, path, gain: -12.db, overwrite: true)).to be_within(0.05).of(set.seconds)
    expect { MB::Sound::Playable.graph(path) }.to raise_error(MB::Sound::Playable::Unplayable, /tracker module/)
    expect(MB::Sound::Tracker.module_file?(path)).to be(true)
    expect(MB::Sound::Tracker.module_file?(tmp_path('x.mod'))).to be(false)
  end
end
