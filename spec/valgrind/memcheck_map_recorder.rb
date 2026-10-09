# Records which extension methods each memcheck spec file calls, for
# selective memcheck (spec/valgrind/memcheck_selection.rb).  Loaded by
# spec_helper when MEMCHECK_MAP=1 (`rake memcheck:map` runs the memcheck
# specs natively with it) and merged into spec/valgrind/memcheck_map.json:
# entries for the spec files that ran are replaced, others kept.
#
# A TracePoint on :c_call checks each called C method's owner once (cached
# per class): methods of a module or class an extension defines
# (MB::Sound::FastSynth.oscillate_bl, FastAudio::Playback#write, ...) are
# recorded for the current spec file (set by context and example hooks;
# calls at load time are attributed through the caller's location).
# Specs under spec/ext/ also map to the extension their name starts with,
# for calls made in subprocesses.
require_relative 'memcheck_selection'

module MemcheckMapRecorder
  MODULES = MemcheckSelection.module_extensions

  @calls = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = Set.new } }
  @seen = Set.new
  @owners = {}.compare_by_identity
  @current = nil
  @pid = Process.pid

  class << self
    attr_accessor :current
    attr_reader :calls, :seen

    # [extension, label prefix, {method => label}] for a method owner, or
    # false.
    def owner_info(klass)
      @owners.fetch(klass) do
        @owners[klass] = begin
          singleton = klass.singleton_class?
          target = singleton ? klass.attached_object : klass
          name = target.is_a?(Module) ? target.name.to_s : ''
          fast = name.split('::').find { |n| MODULES.key?(n) }
          if fast
            short = name.sub(/\A.*?(?=#{fast}\b)/, '')
            [MODULES[fast], singleton ? "#{short}." : "#{short}#", {}]
          else
            false
          end
        rescue StandardError
          false
        end
      end
    end

    def spec_path(path)
      path.to_s.delete_prefix('./').delete_prefix("#{MemcheckSelection::ROOT}/")
    end

    # Allocation-free once a method has been seen (specs count allocations).
    def record(tp)
      info = owner_info(tp.defined_class)
      return unless info

      file = @current
      unless file
        file = caller_locations.map(&:path).find { |p| p.end_with?('_spec.rb') }
        return unless file

        file = spec_path(file)
      end

      id = tp.method_id
      @calls[file][info[0]] << (info[2][id] ||= "#{info[1]}#{id}")
    end

    def write
      return unless Process.pid == @pid

      list = MemcheckSelection.spec_files
      file = MemcheckSelection.path(MemcheckSelection::MAP_PATH)
      map = MemcheckSelection.load_map(file)
      specs = map.fetch('specs')
      (@seen | @calls.keys).each do |s|
        next unless list.include?(s)

        entry = @calls.fetch(s, {}).transform_values { |v| v.to_a.sort }
        static = MemcheckSelection.static_extension(s)
        entry[static] ||= [] if static
        specs[s] = entry.sort.to_h
      end
      specs.select! { |s, _| list.include?(s) }

      out = {
        'about' => 'Extensions (and their methods) each memcheck spec file calls; `rake memcheck:map` regenerates it.  See spec/valgrind/memcheck_selection.rb.',
        'generated' => Time.now.utc.strftime('%Y-%m-%d'),
        'specs' => specs.sort.to_h,
      }
      File.write(file, JSON.pretty_generate(out) + "\n")
      warn "MEMCHECK_MAP: wrote #{MemcheckSelection::MAP_PATH} (#{(@seen | @calls.keys).count { |s| list.include?(s) }} spec files recorded, #{specs.length} in the map)"
    end
  end

  TRACE = TracePoint.new(:c_call) { |tp| MemcheckMapRecorder.record(tp) }
end

RSpec.configure do |config|
  config.prepend_before(:context) do
    f = MemcheckMapRecorder.spec_path(self.class.metadata[:rerun_file_path] || self.class.metadata[:file_path])
    MemcheckMapRecorder.current = f
    MemcheckMapRecorder.seen << f
  end

  config.around(:each) do |example|
    f = MemcheckMapRecorder.spec_path(example.metadata[:rerun_file_path])
    MemcheckMapRecorder.current = f
    MemcheckMapRecorder.seen << f
    example.run
  end

  config.before(:suite) { MemcheckMapRecorder::TRACE.enable }
  config.after(:suite) do
    MemcheckMapRecorder::TRACE.disable
    MemcheckMapRecorder.write
  end
end

# Calls at load time (describe bodies, let constants)
MemcheckMapRecorder::TRACE.enable
