module MB
  module Sound
    module GraphNode
      # A reusable writable copy of frozen input buffers, for nodes that
      # process their input in place: such nodes must copy a frozen input
      # (a Tee's shared buffer, a Constant's steady buffer) before changing
      # it (see Tee).  #copy reuses one buffer while the type and length
      # stay the same, so a frozen input costs no allocation per buffer
      # (MB::Sound::FastArithmetic.copy).
      #
      # The copy is overwritten by the next call, like any node's output
      # buffer.
      class FrozenCopy
        # Returns a writable buffer of the same type and length as +buf+
        # (an NArray) holding its values.  Works for unfrozen buffers too
        # (e.g. a scratch copy to convert in place).
        def copy(buf)
          c = @buf
          return @buf = buf.dup if c.nil? || c.class != buf.class || c.length != buf.length || c.frozen?

          c[0..] = buf unless MB::Sound::FastArithmetic.copy(c, buf)
          c
        end
      end
    end
  end
end
