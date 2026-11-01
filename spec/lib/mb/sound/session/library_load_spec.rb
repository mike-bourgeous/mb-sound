require 'open3'
require 'rbconfig'

# Loading a library instrument onto a playing track (load-lag-1; the
# maintainer's "Loading something from the library is pretty glitchy and
# laggy", 2026-10-31: `track :bowl, L.inst.acid` with the sound screen up).
# Measured (Mac container, YJIT, 800-frame realtime Session): the first
# spill in a session compiled the replaced graph's choke path in the
# landing buffer (30-53 ms, 13-29 iseqs), and Session#add held the render
# lock 7-23 ms walking the new graph for its bus taps (a digibrass or
# SQ-80 load) or, when the build ran past the launch point, landing the
# change on the console thread.  The guards: nothing walks a graph while
# the render lock is held, and a warmed spill leaves little to compile
# where it lands.
RSpec.describe('Loading a library instrument onto a playing track', :aggregate_failures) do
  after { MB::Sound.rewind }

  # An offline Session at +frames+ playing track :lead on +first+ (an
  # instrument) with a looping clip, for +buffers+ buffers.
  def playing_session(first, frames: 256, buffers: 200)
    out = MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: frames)
    s = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2, buffer_size: frames,
                               realtime: false, raise_errors: true)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead, first, MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3).n8.loop)
      MB::Sound.bg(:lead)
      buffers.times { s.process_buffer }
    end
    s
  end

  it 'walks no graph while the render lock is held, on the console thread or where the change lands' do
    s = playing_session(:init)
    lock = s.instance_variable_get(:@render_lock)
    walks = []
    allow(MB::Sound::GraphNode).to receive(:graph).and_wrap_original { |m, *a, **k|
      if lock.mon_owned?
        trace = caller_locations(1, 16).map(&:to_s)
        # (the specs' structure check, Strip.structure_check, walks the
        # session's graphs on purpose)
        walks << trace.grep(%r{lib/mb/sound}).first(3) unless trace.any? { |l| l.include?('check_structure') }
      end
      m.call(*a, **k)
    }
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead, MB::Sound::L.inst.acid)
      400.times { s.process_buffer }
      expect(s.spills).to eq(1)
      MB::Sound.track(:lead, MB::Sound::L.kit.tr909)
      400.times { s.process_buffer }
      expect(s.spills).to eq(2)
    end
    expect(walks).to eq([])
  ensure
    s&.close
  end

  # Arrangement#track checks a patch by building it; for a playing track's
  # new instrument that build is the rebuild's (PatchCheck#check_build),
  # so a preset builds once (a digibrass build is ~100-200 ms), drawing
  # the seeds one build draws.
  it "builds a playing track's new instrument once, drawing one build's seeds" do
    s = playing_session(:init)
    builds = 0
    allow(MB::Sound).to receive(:preset).and_wrap_original { |m, *a, **k, &b| builds += 1; m.call(*a, **k, &b) }
    MB::Sound::Session.with_context(session: s) do
      before = MB::Sound::Internal.root_rng.dup
      MB::Sound.track(:lead, MB::Sound::L.inst.digibrass)
      expect(builds).to eq(1)
      # (a library preset's seeds are saved in its document: no draws)
      expect(MB::Sound::Internal.root_rng).to eq(before)

      # An instrument whose build draws seeds (rain's random phases): the
      # generator moves on as one build of it moves it
      entry = MB::Sound::L.inst.rain
      clip = s.arrangement.tracks[:lead].clip
      MB::Sound::Internal.restore_rng(Random.new(5), 5)
      MB::Sound.track(:lead, entry)
      after = MB::Sound::Internal.root_rng.dup
      MB::Sound::Internal.restore_rng(Random.new(5), 5)
      MB::Sound::Arrangement::InstrumentPatch.patch(entry).call(clip)
      expect(after).to eq(MB::Sound::Internal.root_rng)
      expect(after).not_to eq(Random.new(5))
    end
  ensure
    s&.close
  end

  # GraphNodeInput#prime (Session#add, on the building thread) calls
  # #prime_render on nodes that respond to it: a private one is skipped
  # without a word (Drums::Voice's was, from alloc-2 to load-lag-1, so
  # every kit voice set up its skipping in its first buffer, on the render
  # thread).
  it 'finds every prime_render public, so Session#add primes it' do
    hidden = ObjectSpace.each_object(Class).select { |c| c.private_method_defined?(:prime_render) || c.protected_method_defined?(:prime_render) }
    expect(hidden.map(&:name)).to eq([])
  end

  # With YJIT (in a subprocess: specs run without it), as compiled blocks
  # (they don't depend on machine load the way compile milliseconds do; see
  # warming_spec.rb): the landing of a new instrument whose warm-up ran
  # (Session::Warming#warm_spill: the copy spilled in the sandbox with the
  # knobs turning, and the spill exercise) against one that didn't.
  it 'leaves little for YJIT to compile where a warmed instrument change spills the playing graph' do
    skip 'needs YJIT' unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)

    script = <<~'RUBY'
      require 'mb/sound'
      out = MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: 256)
      s = MB::Sound::Session.new(output: out, realtime: false, buffer_size: 256, channels: 2, raise_errors: true)
      s.warm_changes = ENV['WARM'] == '1'
      compiled = -> { RubyVM::YJIT.runtime_stats[:compiled_block_count] }
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.track(:lead, :init, MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3).n8.loop)
        MB::Sound.bg(:lead)
        600.times { s.process_buffer }
        MB::Sound.track(:lead, MB::Sound::L.inst.acid)
        landing = nil
        600.times do
          c = compiled.call
          spills = s.spills
          s.process_buffer
          next if s.spills == spills
          landing = compiled.call - c
          break
        end
        abort 'no spill' unless landing
        puts "landing #{landing}"
      end
      s.close
    RUBY
    # (both at once: each is a few seconds of building and warming)
    runs = %w[0 1].map { |w|
      Thread.new { Open3.capture2e({ 'MB_SOUND_YJIT' => '1', 'WARM' => w }, RbConfig.ruby, '-I', File.expand_path('../../../../../lib', __dir__), '-e', script) }
    }.map(&:value)
    landing = runs.map { |out, status|
      expect(status).to be_success, out
      Integer(out[/landing (\d+)/, 1])
    }
    # (Mac container, 2026-11-01: cold 3149-3197 blocks, warm 46; before
    # load-lag-1 a warmed change still compiled 662-776 there: the choke
    # path and the reused knobs' turns)
    expect(landing[1]).to be < [250, landing[0] / 8].min
  end
end
