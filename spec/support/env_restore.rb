# Environment variables that steer outputs and live behavior are put back
# after every example (2026-11-21: several specs deleted OUTPUT_TYPE instead
# of restoring it, so a later example in the same process opened a real
# device instead of NullOutput; schedule_methods_spec, script_runner_spec,
# playback_methods_spec, player_spec, playback_end_spec, playable_spec and
# io_methods_spec followed the pattern).  An example may change or delete
# them freely; the value it started with comes back after it, so the class
# of leak is closed here rather than in each spec.
module EnvRestore
  NAMES = %w[OUTPUT_TYPE INPUT_TYPE MB_SOUND_CHECKOUT_TMP MB_SOUND_GOLDEN_DIR].freeze

  def self.snapshot = NAMES.to_h { |n| [n, ENV[n]] }

  def self.restore(saved)
    saved.each do |name, value|
      next if ENV[name] == value
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end
end

RSpec.configure do |config|
  config.around(:each) do |example|
    saved = EnvRestore.snapshot
    begin
      example.run
    ensure
      EnvRestore.restore(saved)
    end
  end
end
