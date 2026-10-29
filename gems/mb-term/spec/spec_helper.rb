# mb-term's specs run on their own: nothing here loads mb-sound (see
# boundary_spec.rb).
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'mb/term'
require 'tmpdir'

# Warnings fail the example that printed them (mb-sound's rule, kept here
# without its machinery).
module MBTermSpecWarnings
  @seen = []
  class << self
    attr_reader :seen
  end

  def warn(message, category: nil, **)
    MBTermSpecWarnings.seen << message
    super
  end
end
Warning.extend(MBTermSpecWarnings)
Warning[:deprecated] = true
Warning[:performance] = true if Warning.respond_to?(:categories) && Warning.categories.include?(:performance)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)

  config.before { MBTermSpecWarnings.seen.clear }
  config.after do |example|
    next if example.exception || MBTermSpecWarnings.seen.empty?

    raise "Warnings in #{example.location}:\n#{MBTermSpecWarnings.seen.join}"
  end

  # A fresh temporary directory per example.
  config.around do |example|
    Dir.mktmpdir('mb-term-spec') do |dir|
      @spec_tmp = dir
      example.run
    end
  end
end

def tmp_path(name) = File.join(@spec_tmp, name)
