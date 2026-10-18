# Joins sample buffers in one copy: SpecBuffers.join(list) is
# list.reduce(:concatenate) (the first buffer's class, upcast like it,
# nil for an empty list, the buffer itself for one) without copying the
# growing result once per buffer.  The reduce was quadratic: 12000
# 64-sample buffers took 2.2 s and 75000 one-sample buffers 2.1 s, most
# of take_spec's and the one-sample buffer_size_invariance renders' time
# (test-speed-2).  spec/spec_hygiene_spec.rb keeps the reduce out of
# specs and lib.
module SpecBuffers
  def self.join(list)
    list = list.to_a
    return nil if list.empty?
    return list[0] if list.length == 1

    list[0].concatenate(*list[1..])
  end
end
