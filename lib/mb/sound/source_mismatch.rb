module MB
  module Sound
    # Raised by a patch or instrument given a source it can't play from
    # (e.g. a TR-808 kit given only notes that map to none of its voices),
    # as opposed to a mistake in the patch itself.  Arrangement::PatchCheck
    # lets these pass when it builds a patch from its test clip, since the
    # real clip may fit (ux-r3 item 6).
    class SourceMismatch < ArgumentError
    end
  end
end
