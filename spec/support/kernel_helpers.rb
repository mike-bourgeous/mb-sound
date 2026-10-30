# Helpers for comparing C kernels with their Ruby mirrors (MB::Sound::Kernels;
# design/notes/kernels.md).
module KernelHelpers
  # node.sample(count) with every kernel in +mode+ (:c, :ruby, or :check).
  def sample_with(mode, node, count)
    MB::Sound::Kernels.with(mode) { node.sample(count) }
  end
end

RSpec.configure do |config|
  config.include KernelHelpers

  # Every example starts with the kernels MB_SOUND_KERNELS chose (an example
  # that set a mode without Kernels.with would leak it)
  config.before(:each) { MB::Sound::Kernels.reset! }
end
