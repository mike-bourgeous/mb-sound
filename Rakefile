require "bundler/gem_tasks"
require 'rake/extensiontask'

task :default => :spec

Rake::ExtensionTask.new 'mb-fast_sound' do |ext|
  ext.name = 'fast_sound'
  ext.ext_dir = 'ext/mb/fast_sound'
  ext.lib_dir = 'lib/mb'
end

Rake::ExtensionTask.new 'mb-sound-fast_resample' do |ext|
  ext.name = 'fast_resample'
  ext.ext_dir = 'ext/mb/sound/fast_resample'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_wavetable' do |ext|
  ext.name = 'fast_wavetable'
  ext.ext_dir = 'ext/mb/sound/fast_wavetable'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_delay' do |ext|
  ext.name = 'fast_delay'
  ext.ext_dir = 'ext/mb/sound/fast_delay'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_synth' do |ext|
  ext.name = 'fast_synth'
  ext.ext_dir = 'ext/mb/sound/fast_synth'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_clip' do |ext|
  ext.name = 'fast_clip'
  ext.ext_dir = 'ext/mb/sound/fast_clip'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_arithmetic' do |ext|
  ext.name = 'fast_arithmetic'
  ext.ext_dir = 'ext/mb/sound/fast_arithmetic'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_envelope' do |ext|
  ext.name = 'fast_envelope'
  ext.ext_dir = 'ext/mb/sound/fast_envelope'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_resonator' do |ext|
  ext.name = 'fast_resonator'
  ext.ext_dir = 'ext/mb/sound/fast_resonator'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_filter' do |ext|
  ext.name = 'fast_filter'
  ext.ext_dir = 'ext/mb/sound/fast_filter'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_loudness' do |ext|
  ext.name = 'fast_loudness'
  ext.ext_dir = 'ext/mb/sound/fast_loudness'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_unison' do |ext|
  ext.name = 'fast_unison'
  ext.ext_dir = 'ext/mb/sound/fast_unison'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_audio' do |ext|
  ext.name = 'fast_audio'
  ext.ext_dir = 'ext/mb/sound/fast_audio'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_midi' do |ext|
  ext.name = 'fast_midi'
  ext.ext_dir = 'ext/mb/sound/fast_midi'
  ext.lib_dir = 'lib/mb/sound'
end


# Valgrind memcheck of the C extensions (`bundle exec rake memcheck`), using
# ruby_memcheck, which runs rspec under Valgrind and filters out Ruby's own
# leaks.  Invalid reads/writes are reported wherever they happen; leaks only
# when an extension's code is on the allocation stack.  Needs valgrind >=
# 3.20 (apt install valgrind).  Takes several minutes.
#
#   MEMCHECK_SPECS="spec/a_spec.rb spec/b_spec.rb"  run other specs
#   MEMCHECK_GEN_SUPPRESSIONS=1                     print suppressions for errors
#   MEMCHECK_GC_STRESS=1                           GC.stress during each extension call
#                                                   (spec/valgrind/gc_stress_calls.rb)
#   MEMCHECK_UNDEF=1                                also report uses of uninitialized
#                                                   values with an extension on the stack
#   rake memcheck:debug                             rebuild extensions at -O0 first
#
# Suppressions for known false positives go in spec/valgrind/ruby.supp (or
# ruby-4.0.supp etc. for one Ruby version).
MEMCHECK_SPECS = [
  # Direct tests of every extension function
  'spec/ext/**/*_spec.rb',
  'spec/lib/mb/fast_sound_spec.rb',

  # Ruby classes whose inner loops are in C (cross-checks against Ruby
  # reference implementations, odd buffer sizes, wraparound)
  'spec/lib/mb/sound/delay_line_spec.rb',          # FastDelay.read/feedback
  'spec/lib/mb/sound/graph_node/multitap_delay_spec.rb',
  'spec/lib/mb/sound/filter/delay_spec.rb',
  'spec/lib/mb/sound/tone_phasor_spec.rb',         # FastSound.phasor/oscillate
  'spec/lib/mb/sound/tone_waveforms_spec.rb',      # FastSound.osc/oscillate, FastSynth.oscillate_bl
  'spec/lib/mb/sound/generation_methods_spec.rb',  # FastSound noise (splitmix64 state)
  'spec/lib/mb/sound/band_limit_spec.rb',          # FastSynth.oscillate_bl/blit/oscillate_sync
  'spec/lib/mb/sound/tone_feedback_spec.rb',       # FastSynth.feedback_sine through Tone (resets, nodes)
  'spec/lib/mb/sound/tone_gain_spec.rb',           # FastArithmetic.scale through Tone#gain
  'spec/lib/mb/sound/shaper_spec.rb',              # FastClip.shape
  'spec/lib/mb/sound/graph_node/curve_shaper_spec.rb', # FastClip.shape_curve
  'spec/lib/mb/sound/curve_spec.rb',               # FastClip.curve_lookup
  'spec/lib/mb/sound/envelope_spec.rb',            # FastEnvelope.process
  'spec/lib/mb/sound/envelope_segments_spec.rb',   # FastEnvelope.process (segment lists, loops)
  'spec/lib/mb/sound/filter/four_pole_spec.rb',    # FastFilter.four_pole
  'spec/lib/mb/sound/filter/svf_spec.rb',          # FastFilter.svf
  'spec/lib/mb/sound/graph_node/resonator_spec.rb', # FastResonator.ping
  'spec/lib/mb/sound/loudness_spec.rb',            # FastLoudness.true_peak
  'spec/lib/mb/sound/wavetable_spec.rb',           # FastWavetable
  'spec/lib/mb/sound/graph_node/wavetable_spec.rb',
  'spec/lib/mb/sound/tone_wavetable_spec.rb',      # FastWavetable through Tone (sync, resets, sample mode)
  'spec/lib/mb/sound/graph_node/harmonic_table_spec.rb',
  'spec/lib/mb/sound/filter/biquad_spec.rb',       # FastSound.biquad*
  'spec/lib/mb/sound/filter/cookbook_spec.rb',     # FastSound.cookbook, dynamic_biquad
  'spec/lib/mb/sound/filter/smoothstep_spec.rb',   # FastSound.smoothstep*
  'spec/lib/mb/sound/graph_node/resample_spec.rb', # FastResample (libsamplerate)
  'spec/lib/mb/sound/graph_node/constant_spec.rb', # FastSound.smootherstep_buf
  'spec/lib/mb/sound/device_output_spec.rb',       # FastAudio::Playback
  'spec/lib/mb/sound/device_input_spec.rb',        # FastAudio::Capture
  'spec/lib/mb/sound/midi/input_spec.rb',          # MIDI::Input on JACK and RtMidi (with a JACK dummy server)
  'spec/lib/mb/sound/midi/live_source_spec.rb',    # Playback#jack_clock (with a JACK dummy server)
  'spec/lib/mb/sound/jack_spec.rb',                # DeviceOutput/Input and MIDI on one JACK client
].freeze

begin
  require 'ruby_memcheck'
  require 'ruby_memcheck/rspec/rake_task'

  # Valgrind stops writing a process's XML when it execs a program that
  # --trace-children-skip excludes (e.g. `sh -c ffmpeg ...`), and
  # ruby_memcheck aborts on the unterminated file.  Close such files before
  # parsing; a truncated file still reports any errors written before the
  # exec.
  module MemcheckTruncatedXml
    private def parse_valgrind_output
      valgrind_xml_files.each do |f|
        xml = File.read(f)
        next if xml.include?('</valgrindoutput>')
        # Cut after the last complete top-level element, then close the root
        ends = xml.to_enum(:scan, %r{<valgrindoutput>|</(?:preamble|args|status|error|errorcounts|suppcounts)>}).map { $~.end(0) }
        File.write(f, "#{xml[0...ends.last.to_i]}\n</valgrindoutput>\n")
      end
      super
    end
  end
  RubyMemcheck::TestTaskReporter.prepend(MemcheckTruncatedXml)

  # With MEMCHECK_UNDEF=1, Ruby's conservative GC stack scanning gives
  # thousands of uninitialized-value errors (gc_mark_set, is_pointer_to_heap,
  # ...), many while an extension is on the stack.  Keep only those where
  # the value is used in this project's extensions, or in a library they
  # called (libm, libsamplerate, ...), before control returns to libruby.
  module MemcheckUndefFilter
    EXT_DIR = File.join(__dir__, 'lib', '')

    def skip?
      return super unless kind.start_with?('Uninit')

      stack.frames.take_while { |f| !f.in_ruby? }.none? { |f| f.obj.to_s.start_with?(EXT_DIR) }
    end
  end
  RubyMemcheck::ValgrindError.prepend(MemcheckUndefFilter)

  # Built when the task runs: RubyMemcheck::Configuration creates a temp
  # directory, which would otherwise be left behind by every rake command.
  memcheck_config = lambda do
    RubyMemcheck::Configuration.new(
      valgrind_options: [
        *RubyMemcheck::Configuration::DEFAULT_VALGRIND_OPTIONS,
        *(ENV['MEMCHECK_UNDEF'] == '1' ? ['--undef-value-errors=yes', '--track-origins=yes'] : []),
        # --trace-children=yes (a default) keeps the GC.stress `ruby -e` load
        # specs under Valgrind; ffmpeg and other tools run natively.  A
        # process that execs a skipped program leaves truncated XML, which
        # MemcheckTruncatedXml above cleans up.
        # jackd: the MIDI specs' dummy JACK server (spec/support/jack_dummy.rb),
        # started through setpriv.
        '--trace-children-skip=*ffmpeg*,*ffprobe*,*gnuplot*,*/dot,*/git,*jackd*,*setpriv*',
        # Forked children that don't exec (fork_script) would repeat the
        # parent's leak report, so only exec'd programs report.
        '--child-silent-after-fork=yes',
      ],
      valgrind_suppressions_dir: 'spec/valgrind',
      valgrind_generate_suppressions: ENV['MEMCHECK_GEN_SUPPRESSIONS'] == '1',
    )
  end

  desc 'Run the C extension specs under Valgrind memcheck (MEMCHECK_SPECS=... for others)'
  task memcheck: :compile do
    config = memcheck_config.call
    RubyMemcheck::RSpec::RakeTask.new(config, :memcheck_rspec) do |t|
      specs = ENV['MEMCHECK_SPECS'].to_s.split
      t.pattern = specs.empty? ? MEMCHECK_SPECS : specs
      t.rspec_opts = ['--format', 'progress']
      t.rspec_opts += ['--require', './spec/valgrind/gc_stress_calls.rb'] if ENV['MEMCHECK_GC_STRESS'] == '1'
    end
    Rake::Task[:memcheck_rspec].invoke
  ensure
    FileUtils.rm_rf(config.temp_dir) if config
  end

  namespace :memcheck do
    desc 'Rebuild the extensions at -O0 (exact Valgrind line numbers), then run memcheck; `rake clobber compile` restores -O3'
    task :debug do
      # Later flags win, so these override extconf.rb's -O3.  -O0 disables
      # _FORTIFY_SOURCE, whose warning would fail -Werror.
      ENV['EXTRACFLAGS'] = "-O0 -U_FORTIFY_SOURCE #{ENV['EXTRACFLAGS']}"
      Rake::Task['clobber'].invoke # extconf flags are only read when tmp/ is empty
      Rake::Task['memcheck'].invoke
    end
  end
rescue LoadError => e
  desc 'Run the C extension specs under Valgrind memcheck (needs the ruby_memcheck gem)'
  task(:memcheck) { abort "rake memcheck needs the ruby_memcheck gem (bundle install): #{e.message}" }
end
