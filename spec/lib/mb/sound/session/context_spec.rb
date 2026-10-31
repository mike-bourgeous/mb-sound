# The command context (session-core-1, arch-session section 5): who issued
# the commands running on a thread, and when, is one frozen
# Session::Context instead of eight thread-local keys; other thread-local
# settings go through Internal.with_local, and every thread-local key is
# listed here with what it holds, so a new one is a decision (provenance
# belongs in Session::Context).
RSpec.describe(MB::Sound::Session::Context, :aggregate_failures) do
  let(:session_class) { MB::Sound::Session }
  let(:a) { session_class.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new, realtime: false) }
  let(:b) { session_class.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new, realtime: false) }

  after do
    a.close
    b.close
  end

  # key => what it holds
  keys = {
    mb_sound_context: 'Session::Context: who issued the commands running on this thread, and when',
    mb_sound_span: 'the span a Session renders on this thread (Session.span; render path)',
    mb_sound_plan_deferral: 'the plan rebuild deferral of the render (render path)',
    mb_sound_tee_new_branches: 'Tee.collect_branches: branches made while building',
    mb_sound_tee_rate_pins: 'Tee.pin_rates: branches resampled out of an oversample region',
    mb_sound_inspecting: 'GraphNode::Inspect: no nested one-line inspects',
    mb_sound_pry_command: 'the running Pry command, for the pager',
    mb_steer_origin: 'Generative::Steer.origin while a ClipSource reads (render path)',
    sound_io_log_depth: 'nesting depth of sound I/O logs',
    mb_sound_ui_repl: 'the UI REPL host on its thread',
    mb_sound_ui_tiles: 'the tiles screen on its thread',
    mb_sound_rack_applications: 'racks being applied (nested), for their ports',
    mb_sound_preview_slack: 'the sound-design preview worker pacing state',
    mb_sound_preview_frames: 'the sound-design preview worker frame source',
    mb_sound_mixer_ring: 'Mixer.with_ring: how sums built in the block end',
    mb_sound_bound_document_params: 'Arrangement::LiteralBinding: bound graph document params',
    mb_wavetable_shape: 'wavetable shape cache of this thread',
    mb_sound_synth_lane: 'Synth.with_lane: the lane a voice block builds',
    mb_sound_script_declarations: 'ScriptRunner.declarations_of: the script being scanned',
    mb_sound_recipe: 'GraphNode::Recipe recording state',
    mb_sound_quiet_seconds: 'DelayMethods.quiet_seconds: no deprecation warning',
    mb_sound_quiet_levels: 'Decibels.quietly: no above-full-scale warnings',
    mb_sound_mastering: 'Mastering.building: trims and captured presets',
    mb_sound_knob_landings: 'Arrangement::TrackKnobs.deferring: knob values an instrument change turns at its launch point',
    mb_sound_knob_reset: 'Arrangement::TrackKnobs.resetting: a new instrument starts every reused knob at its own value',
    mb_param_peek: 'MIDI::Param.peek: reads that decide nothing',
    scene_profile: 'bin/scene_profile.rb measurements',
  }.freeze

  it 'lists every thread-local key in lib/, bin/, and gems/ with what it holds' do
    root = File.expand_path('../../../../..', __dir__)
    found = Dir.glob(File.join(root, '{lib,bin,gems/*/lib}/**/*.rb')).flat_map { |f|
      File.read(f).scan(/Thread\.current\[:(\w+)\]|with_local\(:(\w+)/).flatten.compact
    }.uniq.map(&:to_sym)
    expect(found - keys.keys).to eq([]), 'new thread-local keys: list them here (a command\'s provenance goes in Session::Context instead)'
    expect(keys.keys - found).to eq([]), 'keys no longer used: remove them from the list'
  end

  it 'sets only its own fields while a block runs, and puts them back' do
    session_class.with_context(session: a, time: 3r, source: :schedule) do
      expect(session_class.context.session).to equal(a)
      session_class.with_context_fields(deadline: [a, 'bar 2']) do
        session_class.with_context(session: b) do
          c = session_class.context
          expect([c.session, c.time, c.source, c.deadline]).to eq([b, nil, nil, [a, 'bar 2']])
        end
        expect(session_class.context.time).to eq(3r)
      end
      expect(session_class.context.deadline).to be_nil
      expect(session_class.current).to equal(a)
    end
    expect(session_class.context.session).to be_nil
  end

  it 'puts fields back when the block raises' do
    expect { session_class.with_context(session: a) { raise 'x' } }.to raise_error('x')
    expect(session_class.context.session).to be_nil
  end

  it 'answers the logical time and source per Session: a replayed line, else a scheduled block' do
    session_class.with_context(session: a, time: 2r, source: :replay) do
      expect(session_class.context.now_for(a)).to eq(2r)
      expect(session_class.context.now_for(b)).to be_nil
      session_class.with_perform(session: a, forced: [5r], now: 4r, source: :replay) do
        c = session_class.context
        expect(c.now_for(a)).to eq(4r)
        expect(c.time_for(a)).to eq(2r)
        expect(c.source_for(a)).to eq(:replay)
        expect(c.replaying?).to be(true)
        expect(c.forced.shift).to eq(5r)
        session_class.with_perform(source: :undo) do
          expect(session_class.context.source_for(a)).to eq(:undo)
          expect(session_class.context.now_for(a)).to eq(4r)
        end
      end
      expect(session_class.context.source_for(a)).to eq(:replay) # (the issuing context's)
      expect(session_class.context.source_for(b)).to eq(:replay)
    end
    expect(session_class::Context::NONE.source_for(a)).to eq(:console)
    expect(a.now).to eq(a.transport.position)
  end

  it 'refuses settings it does not have' do
    expect { session_class.with_perform(line: 3) {} }.to raise_error(ArgumentError, /line/)
    expect { session_class.with_context(transport: a.transport) {} }.to raise_error(ArgumentError)
  end

  it 'prints only the fields that are set' do
    session_class.with_context(session: a, time: 1r) do
      expect(session_class.context.inspect).to eq("#<Session::Context session: #{a.inspect}, time: (1/1)>")
    end
  end

  it 'restores a thread-local setting with Internal.with_local' do
    expect(MB::Sound::Internal.with_local(:mb_param_peek, true) { MB::Sound::MIDI::Param.peeking? }).to be(true)
    expect(MB::Sound::MIDI::Param.peeking?).to be(false)
  end
end
