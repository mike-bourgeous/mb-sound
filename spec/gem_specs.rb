# The specs of the gems in gems/ (mb-term: the terminal UI's generic layers),
# each in its own rspec process from its own directory with its own bundle
# (gems/<gem>/Gemfile and Gemfile.lock), so they run without mb-sound loaded.
# Used by the Rakefile's spec tasks and the merge gate.
module GemSpecs
  ROOT = File.expand_path('..', __dir__)

  # The gems in gems/ whose specs run in their own processes.
  DIRS = %w[gems/mb-term].freeze

  module_function

  # The environment for a gem's own bundle (a parent `bundle exec` leaves
  # BUNDLE_GEMFILE pointing at mb-sound's Gemfile otherwise).
  def env(dir)
    { 'BUNDLE_GEMFILE' => File.join(ROOT, dir, 'Gemfile') }
  end

  # Runs +args+ (default: rspec) under each gem's bundle from its directory,
  # outside the calling bundle.  Returns true if every run passed.
  def run(*args, label: 'spec')
    args = %w[rspec] if args.empty?
    DIRS.select { |d| Dir.exist?(File.join(ROOT, d)) }.all? do |dir|
      puts "#{label}: #{dir} specs"
      cmd = -> { system(env(dir), 'bundle', 'exec', *args, chdir: File.join(ROOT, dir)) }
      defined?(Bundler) ? Bundler.with_unbundled_env(&cmd) : cmd.call
    end
  end
end
