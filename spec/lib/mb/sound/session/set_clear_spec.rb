# Clearing the set (fixes-15; the maintainer, 2026-11-18: "A new demo
# should replace the entire previous demo"): Session#clear_set and the
# console's clear_set stop everything and take the set out in one undo
# step; undo swaps the same set back (its players at the undo's launch
# point), redo the cleared one; armed tracks refuse; a block's set (a
# demo's) is what redo puts back, and a block that raises keeps the step.
require_relative '../../../../support/midi_list_source'

RSpec.describe('MB::Sound::Session#clear_set', :aggregate_failures) do
  let(:session) {
    MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, channels: 2,
                           transport: MB::Sound::Sequence::Transport.new(bpm: 120))
  }

  after {
    session.close
    MB::Sound.rewind
  }

  def run(n = 1, &block)
    value = MB::Sound::Session.with_context(session: session, &block) if block
    n.times { session.process_buffer(800) }
    value
  end

  def build_set
    run(4) do
      MB::Sound.knob(:echo, 0.3)
      MB::Sound.knob(:cut, (200.hz..6000.hz).at(700.hz))
      MB::Sound.bus(:wet) { |sig| sig * 0.5 }
      MB::Sound.track(:lead) { |c| MB::Sound.synth(c) { |v| v.hz.saw.lp4(MB::Sound.knob(:cut)) * v.amp_env(0.01, 0.1, 0.5, 0.1) * 0.2 } }
      MB::Sound.track(:pad) { |c| MB::Sound.synth(c) { |v| v.hz.sine * v.amp_env(0.01, 0.1, 0.5, 0.1) * 0.2 } }
      MB::Sound.feed(:lead, :wet, -6.db)
      MB::Sound.mutes(:pair, :lead, :pad)
      MB::Sound.scene(:a, lead: MB::Sound.seq(MB::Sound::A3).n4.loop, pad: MB::Sound.seq(MB::Sound::C4).n2.loop)
      MB::Sound.master { |mix| mix.softclip(0.5, 0.97) }
      MB::Sound.clock(:half, 1/2r)
      MB::Sound.go(:a, on: :now)
    end
  end

  it 'stops everything, takes the set out, and frees its names; undo puts the same set back playing, redo clears it again' do
    build_set
    arr = session.arrangement
    knobs = session.knobs.to_h { |n, k| [n, k] }
    expect(session.players.keys).to include(:lead, :pad)
    expect(session.master_info).not_to start_with('bypass')

    expect { run(2) { MB::Sound.clear_set } }.to output(/\Aclear_set: cleared 2 tracks, 1 scene, 2 knobs, 1 bus, and a master chain \(undo puts it back\)\n\z/).to_stdout
    expect(session.players).to be_empty
    expect(session.arrangement).not_to equal(arr)
    expect(session.arrangement.tracks).to be_empty
    expect(session.arrangement.scenes).to be_empty
    expect(session.knobs).to be_empty
    expect(session.bus_names).to be_empty
    expect(session.route_definitions).to be_empty
    expect(session.mute_groups).to be_empty
    expect(session.clocks).to be_empty
    expect(session.master_info).to start_with('bypass')
    expect(session.names.to_h).to be_empty
    expect(session.transport.bpm).to eq(120) # (the tempo stays)

    # (the names are free: the knob :echo's name for a bus)
    run(2) { MB::Sound.bus(:echo) { |sig| sig } }
    expect(session.bus_names).to eq([:echo])
    run(2) { MB::Sound.undo(on: :now) } # (the bus)
    expect { run(2) { MB::Sound.clear_set } }.to output(/clear_set: cleared 1 bus \(undo/).to_stdout
    run(2) { MB::Sound.undo(on: :now) } # (that clear)

    run(4) { MB::Sound.undo(on: :now) } # (the first clear)
    expect(session.arrangement).to equal(arr)
    expect(session.knobs.to_h { |n, k| [n, k] }).to eq(knobs)
    expect(session.knobs[:cut]).to equal(knobs[:cut])
    expect(session.knobs[:cut].value).to eq(700.0)
    expect(session.bus_names).to eq([:wet])
    expect(session.mute_groups).to eq({ pair: %i[lead pad] })
    expect(session.clocks.keys).to eq([:half])
    expect(session.names.to_h).to include(lead: :track, wet: :bus, cut: :knob)
    expect(session.master_info).not_to start_with('bypass')
    expect(session.players.keys).to include(:lead, :pad)

    run(4) { MB::Sound.redo!(on: :now) }
    expect(session.arrangement.tracks).to be_empty
    expect(session.players).to be_empty
    expect(session.master_info).to start_with('bypass')
  end

  it 'keeps the set a block makes for redo, and keeps the step when the block raises' do
    build_set
    arr = session.arrangement
    run(1) {
      session.clear_set(label: 'swap sets') { MB::Sound.knob(:other, 0.25); MB::Sound.master { |mix| mix * 0.5 } }
    }
    expect(session.knobs.keys).to eq([:other])
    expect(session.undo_steps.last.label).to eq('swap sets')

    run(2) { MB::Sound.undo(on: :now) }
    expect(session.arrangement).to equal(arr)
    expect(session.knobs.keys).to eq(%i[echo cut])
    run(2) { MB::Sound.redo!(on: :now) }
    expect(session.knobs.keys).to eq([:other])
    expect(session.master_info).not_to start_with('bypass')

    expect {
      run(1) { session.clear_set(label: 'broken') { MB::Sound.knob(:half_made, 0.5); raise ArgumentError, 'no such set' } }
    }.to raise_error(ArgumentError, 'no such set')
    expect(session.knobs.keys).to eq([:half_made])
    run(2) { MB::Sound.undo(on: :now) }
    expect(session.knobs.keys).to eq([:other])
  end

  # (ux-friction-3: he asked "How do I clear everything in
  # form/track/bg/etc.?"; measured: plain bg players, named and not, and
  # stopped players kept for resume all go)
  it 'stops plain bg players too, and forgets stopped ones kept for resume' do
    run(4) do
      MB::Sound.bg(:hum, 220.hz.sine.at(0.05), on: :now)
      MB::Sound.bg(110.hz.saw.at(0.05), on: :now)
      MB::Sound.bg(:kept, 330.hz.sine.at(0.05), on: :now)
    end
    run(2) { MB::Sound.stop(:kept, fade: 0) }
    expect(session.players.length).to eq(2)
    expect(session.resumable?(:kept)).to eq(true)
    run(2) { session.clear_set }
    expect(session.players).to be_empty
    expect(session.resumable?(:kept)).to eq(false)
  end

  it 'refuses while a track is armed' do
    build_set
    session.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new) # (no live MIDI device here)
    run(1) { MB::Sound.arm(:lead, monitor: false) }
    expect { run { MB::Sound.clear_set } }.to raise_error(ArgumentError, /clear_set: :lead is armed \(disarm :lead first\)/)
    expect(session.arrangement.tracks.keys).to eq(%i[lead pad])
    run(1) { MB::Sound.disarm(:lead) }
  end
end
