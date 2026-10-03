# Turns GC.stress on only while an extension method runs, so a GC at any
# allocation inside the C code (an NArray cast, a block call) collects
# anything the C code forgot to keep alive (a missing RB_GC_GUARD or mark).
# Under Valgrind (`MEMCHECK_GC_STRESS=1 rake memcheck`) the NArray data
# freed by such a GC turns into an "Invalid read"; natively it may crash.
#
# GC.stress for whole examples is far too slow (6.7 min natively for the
# 109 spec/ext examples); per call it is about 10x slower than normal.
# FastResample#read runs its Ruby block under GC.stress too, which makes
# resampling-heavy specs very slow (graph_node/resample_spec).
require 'mb/sound'

module GCStressCalls
  def self.wrap(mod, names)
    mod.prepend(Module.new do
      names.each do |name|
        define_method(name) do |*args, **kwargs, &block|
          prev = GC.stress
          GC.stress = true
          begin
            super(*args, **kwargs, &block)
          ensure
            GC.stress = prev
          end
        end
      end
    end)
  end
end

[MB::FastSound, MB::Sound::FastDelay, MB::Sound::FastWavetable].each do |mod|
  GCStressCalls.wrap(mod.singleton_class, mod.singleton_methods(false))
end
GCStressCalls.wrap(MB::Sound::FastResample, [:read])
