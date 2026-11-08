# Removing a track from the set (tuner-fixes-1; the maintainer, 2026-11-07:
# "How do I remove a track from the tracks list?", 2026-11-08: "Yes" to
# `untrack :clap`, undoable): it stops now, its name is free, undo puts it
# back playing, redo takes it out again; scenes and arms that name it
# refuse.
RSpec.describe('MB::Sound::Arrangement#untrack', :aggregate_failures) do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: false, channels: 1) }

  after {
    session.close
    MB::Sound.rewind
  }

  def run(n = 1, &block)
    MB::Sound::Session.with_context(session: session, &block) if block
    n.times { session.process_buffer }
  end

  def playing?(name) = session.playing_after_queue?(name)

  before do
    run(4) do
      MB::Sound.track(:clap) { |c| MB::Sound.synth(c) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) } }
      MB::Sound.bg(:clap, MB::Sound.seq(MB::Sound::A2).n4.loop)
      MB::Sound.track(:keep) { |c| MB::Sound.synth(c) { |v| v.hz.sine * v.amp_env(0.01, 0.1, 0.5, 0.1) } }
    end
  end

  it 'stops the track, frees its name, and undo puts it back playing; redo takes it out again' do
    tr = session.arrangement.tracks[:clap]
    expect(playing?(:clap)).to eq(true)
    run(4) { MB::Sound.untrack(:clap) }
    expect(session.arrangement.tracks.keys).to eq([:keep])
    expect(playing?(:clap)).to eq(false)
    expect(session.names.to_h).not_to have_key(:clap)
    expect(session.journal.changes.last.subject).to eq(:clap) # (the stop)

    run(4) { MB::Sound.undo(on: :now) }
    expect(session.arrangement.tracks[:clap]).to equal(tr)
    expect(session.names.to_h[:clap]).to eq(:track)
    expect(playing?(:clap)).to eq(true)

    run(4) { MB::Sound.redo!(on: :now) }
    expect(session.arrangement.tracks).not_to have_key(:clap)
    expect(playing?(:clap)).to eq(false)

    # (a stopped track: removed, no stop needed)
    expect(MB::Sound::Session.with_context(session: session) { MB::Sound.untrack(:keep) }).to eq(true)
    expect(session.arrangement.tracks).to be_empty
    run(1) { MB::Sound.undo(on: :now) }
    expect(session.arrangement.tracks.keys).to eq([:keep])
  end

  it 'refuses a track a scene gives a value, an armed one, and a name that is no track' do
    run { MB::Sound.scene(:drop, clap: MB::Sound.seq(MB::Sound::C3).n4.loop) }
    expect { run { MB::Sound.untrack(:clap) } }.to raise_error(ArgumentError, /untrack :clap: scene :drop gives it a value; take it out of that scene first/)
    expect(session.arrangement.tracks).to have_key(:clap)
    expect { run { MB::Sound.untrack(:nope) } }.to raise_error(ArgumentError, /untrack: no track :nope/)
  end
end
