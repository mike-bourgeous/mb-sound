# Loaded through RUBYOPT (see spec/support/subprocess_coverage.rb) into Ruby
# subprocesses started by specs, mostly bin/ scripts.  Records plain Ruby
# Coverage and writes this process's results for project files to its own
# JSON file, which the spec process adds to its SimpleCov report.
#
# Only the stdlib Coverage extension is loaded before the script, so gems
# are still activated by the script's own `require 'bundler/setup'`.
require 'coverage'

Coverage.start(lines: true, branches: true)

at_exit do
  dir = ENV['MB_SOUND_SUBPROCESS_COVERAGE']
  next unless dir && File.directory?(dir)

  require 'json'

  root = File.expand_path('..', __dir__) + '/'
  results = Coverage.result.select { |path, _| path.start_with?(root) && !path.include?('/vendor/') }
  name = File.join(dir, "#{Process.pid}-#{rand(1 << 32).to_s(16)}.json")

  # Written to a temporary name and renamed, so a reader never sees half a file
  File.write("#{name}.part", JSON.dump(results))
  File.rename("#{name}.part", name)
rescue => e
  warn "Could not save subprocess coverage: #{e}"
end

# Coverage only records files loaded after it starts, so the script ($0)
# is loaded from here instead of by Ruby itself (with load, not require, so
# extensionless scripts like binstubs work too).
if File.file?($0)
  load File.expand_path($0)
  exit 0
end
